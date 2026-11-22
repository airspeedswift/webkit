/*
 * Copyright (C) 2019-2025 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "ResourceLoadStatisticsStore.h"

#include "DidFilterKnownLinkDecoration.h"
#include "ITPThirdPartyData.h"
#include "Logging.h"
#include "NetworkProcess.h"
#include "NetworkSession.h"
#include "PrivateClickMeasurementManager.h"
#include "PrivateClickMeasurementManagerProxy.h"
#include "StorageAccessStatus.h"
#include "WebProcessProxy.h"
#include "WebsiteDataStore.h"
#include <JavaScriptCore/ConsoleTypes.h>
#include <WebCore/CookieJar.h>
#include <WebCore/DocumentStorageAccess.h>
#include <WebCore/KeyedCoding.h>
#include <WebCore/OrganizationStorageAccessPromptQuirk.h>
#include <WebCore/PermissionState.h>
#include <WebCore/ResourceLoadStatistics.h>
#include <WebCore/SQLiteDatabase.h>
#include <WebCore/SQLiteStatement.h>
#include <WebCore/SQLiteStatementAutoResetScope.h>
#include <WebCore/StorageAccessQuirks.h>
#include <WebCore/UserGestureIndicator.h>
#include <ranges>
#include <wtf/Borrow.h>
#include <wtf/CallbackAggregator.h>
#include <wtf/CompletionHandler.h>
#include <wtf/CrossThreadCopier.h>
#include <wtf/DateMath.h>
#include <wtf/MathExtras.h>
#include <wtf/Scope.h>
#include <wtf/SuspendableWorkQueue.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/WeakHashSet.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringBuilder.h>

namespace WebKit {
using namespace WebCore;

#define ITP_DEBUG_MODE_RELEASE_LOG(fmt, ...) RELEASE_LOG_INFO(ITPDebug, "ResourceLoadStatisticsStore: " fmt, ##__VA_ARGS__)
#define ITP_RELEASE_LOG_ERROR(fmt, ...) RELEASE_LOG_ERROR(ResourceLoadStatistics, "%p - [sessionID=%" PRIu64 "] - ResourceLoadStatisticsStore::" fmt, this, m_sessionID.toUInt64(), ##__VA_ARGS__)
#define ITP_RELEASE_LOG_DATABASE_ERROR(fmt, ...) RELEASE_LOG_ERROR(ResourceLoadStatistics, "%p - [sessionID=%" PRIu64 ", error=%d, message=%" PRIVATE_LOG_STRING "] - ResourceLoadStatisticsStore::" fmt, this, m_sessionID.toUInt64(), m_database->lastError(), m_database->lastErrorMsg(), ##__VA_ARGS__)


constexpr Seconds minimumStatisticsProcessingInterval { 5_s };


// COUNT Queries
constexpr auto observedDomainCountQuery = "SELECT COUNT(*) FROM ObservedDomains"_s;

// INSERT OR IGNORE Queries
constexpr auto insertObservedDomainQuery = "INSERT INTO ObservedDomains (registrableDomain, lastSeen, hadUserInteraction,"
    "mostRecentUserInteractionTime, grandfathered, isPrevalent, isVeryPrevalent, dataRecordsRemoved, timesAccessedAsFirstPartyDueToUserInteraction,"
    "timesAccessedAsFirstPartyDueToStorageAccessAPI, isScheduledForAllButCookieDataRemoval, mostRecentWebPushInteractionTime) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"_s;

// INSERT OR REPLACE Queries

// EXISTS Queries
constexpr auto subframeUnderTopFrameDomainExistsQuery = "SELECT EXISTS (SELECT 1 FROM SubframeUnderTopFrameDomains WHERE subFrameDomainID = ? "
    "AND topFrameDomainID = (SELECT domainID FROM ObservedDomains WHERE registrableDomain = ?))"_s;
constexpr auto subresourceUnderTopFrameDomainExistsQuery = "SELECT EXISTS (SELECT 1 FROM SubresourceUnderTopFrameDomains "
    "WHERE subresourceDomainID = ? AND topFrameDomainID = (SELECT domainID FROM ObservedDomains WHERE registrableDomain = ?))"_s;
constexpr auto subresourceUniqueRedirectsToExistsQuery = "SELECT EXISTS (SELECT 1 FROM SubresourceUniqueRedirectsTo WHERE subresourceDomainID = ? "
    "AND toDomainID = (SELECT domainID FROM ObservedDomains WHERE registrableDomain = ?))"_s;
constexpr auto storageAccessExistsQuery = "SELECT EXISTS (SELECT 1 FROM StorageAccessUnderTopFrameDomains WHERE domainID = ? AND topLevelDomainID = (SELECT domainID FROM ObservedDomains WHERE registrableDomain = ?))"_s;

// UPDATE Queries
constexpr auto mostRecentUserInteractionQuery = "UPDATE ObservedDomains SET hadUserInteraction = ?, mostRecentUserInteractionTime = ? "_s
    "WHERE registrableDomain = ?"_s;
constexpr auto updateLastSeenQuery = "UPDATE ObservedDomains SET lastSeen = ? WHERE registrableDomain = ?"_s;
constexpr auto updateDataRecordsRemovedQuery = "UPDATE ObservedDomains SET dataRecordsRemoved = ? WHERE registrableDomain = ?"_s;
constexpr auto updatePrevalentResourceQuery = "UPDATE ObservedDomains SET isPrevalent = ? WHERE registrableDomain = ?"_s;
constexpr auto updateVeryPrevalentResourceQuery = "UPDATE ObservedDomains SET isVeryPrevalent = ? WHERE registrableDomain = ?"_s;
constexpr auto clearPrevalentResourceQuery = "UPDATE ObservedDomains SET isPrevalent = 0, isVeryPrevalent = 0 WHERE registrableDomain = ?"_s;
constexpr auto updateGrandfatheredQuery = "UPDATE ObservedDomains SET grandfathered = ? WHERE registrableDomain = ?"_s;
constexpr auto updateIsScheduledForAllButCookieDataRemovalQuery = "UPDATE ObservedDomains SET isScheduledForAllButCookieDataRemoval = ? WHERE registrableDomain = ?"_s;
constexpr auto updateMostRecentWebPushInteractionTimeQuery = "UPDATE ObservedDomains SET mostRecentWebPushInteractionTime = ? WHERE registrableDomain = ?"_s;

// SELECT Queries
constexpr auto domainIDFromStringQuery = "SELECT domainID FROM ObservedDomains WHERE registrableDomain = ?"_s;
constexpr auto domainStringFromDomainIDQuery = "SELECT registrableDomain FROM ObservedDomains WHERE domainID = ?"_s;
constexpr auto domainWithUserInteractionQuery = "SELECT registrableDomain, mostRecentUserInteractionTime FROM ObservedDomains WHERE hadUserInteraction = 1"_s;
constexpr auto isPrevalentResourceQuery = "SELECT isPrevalent FROM ObservedDomains WHERE registrableDomain = ?"_s;
constexpr auto isVeryPrevalentResourceQuery = "SELECT isVeryPrevalent FROM ObservedDomains WHERE registrableDomain = ?"_s;
constexpr auto hadUserInteractionQuery = "SELECT hadUserInteraction, mostRecentUserInteractionTime FROM ObservedDomains WHERE registrableDomain = ?"_s;
constexpr auto isGrandfatheredQuery = "SELECT grandfathered FROM ObservedDomains WHERE registrableDomain = ?"_s;
constexpr auto isScheduledForAllButCookieDataRemovalQuery = "SELECT isScheduledForAllButCookieDataRemoval FROM ObservedDomains WHERE registrableDomain = ?"_s;
constexpr auto getResourceDataByDomainNameQuery = "SELECT * FROM ObservedDomains WHERE registrableDomain = ?"_s;
constexpr auto getMostRecentlyUpdatedTimestampQuery = "SELECT MAX(lastUpdated) FROM (SELECT lastUpdated FROM SubframeUnderTopFrameDomains WHERE subFrameDomainID = ? and topFrameDomainID = ?"_s
    "UNION ALL SELECT lastUpdated FROM TopFrameLinkDecorationsFrom WHERE toDomainID = ? and fromDomainID = ?"
    "UNION ALL SELECT lastUpdated FROM SubresourceUnderTopFrameDomains WHERE subresourceDomainID = ? and topFrameDomainID = ?"
    "UNION ALL SELECT lastUpdated FROM SubresourceUniqueRedirectsTo WHERE subresourceDomainID = ? and toDomainID = ?)"_s;
constexpr auto getAllDomainsQuery = "SELECT registrableDomain FROM ObservedDomains"_s;
constexpr auto getAllSubStatisticsUnderDomainQuery = "SELECT topFrameDomainID FROM SubframeUnderTopFrameDomains WHERE subFrameDomainID = ?"
    "UNION ALL SELECT topFrameDomainID FROM SubresourceUnderTopFrameDomains WHERE subresourceDomainID = ?"
    "UNION ALL SELECT toDomainID FROM SubresourceUniqueRedirectsTo WHERE subresourceDomainID = ?"_s;

// EXISTS for testing queries
constexpr auto linkDecorationExistsQuery = "SELECT EXISTS (SELECT * FROM TopFrameLinkDecorationsFrom WHERE toDomainID = ? OR fromDomainID = ?)"_s;
constexpr auto scriptLoadExistsQuery = "SELECT EXISTS (SELECT * FROM TopFrameLoadedThirdPartyScripts WHERE topFrameDomainID = ? OR subresourceDomainID = ?)"_s;
constexpr auto subFrameExistsQuery = "SELECT EXISTS (SELECT * FROM SubframeUnderTopFrameDomains WHERE subFrameDomainID = ? OR topFrameDomainID = ?)"_s;
constexpr auto subResourceExistsQuery = "SELECT EXISTS (SELECT * FROM SubresourceUnderTopFrameDomains WHERE subresourceDomainID = ? OR topFrameDomainID = ?)"_s;
constexpr auto uniqueRedirectExistsQuery = "SELECT EXISTS (SELECT * FROM SubresourceUniqueRedirectsTo WHERE subresourceDomainID = ? OR toDomainID = ?)"_s;
constexpr auto observedDomainsExistsQuery = "SELECT EXISTS (SELECT * FROM ObservedDomains WHERE domainID = ?)"_s;

// DELETE Queries
constexpr auto removeAllDataQuery = "DELETE FROM ObservedDomains WHERE domainID = ?"_s;
constexpr auto checkIfTableExistsQuery = "SELECT 1 from sqlite_master WHERE type='table' and tbl_name=?"_s;

static constexpr std::array<ASCIILiteral, resourceLoadStatisticsCachedStatementCount> cachedStatementQueries {
#define CACHED_STATEMENT_QUERY(name, query) query,
    FOR_EACH_RESOURCE_LOAD_STATISTICS_CACHED_STATEMENT(CACHED_STATEMENT_QUERY)
#undef CACHED_STATEMENT_QUERY
};
static constexpr std::array<ASCIILiteral, resourceLoadStatisticsStatementLogLabelCount> statementLogLabels {
#define STATEMENT_LOG_LABEL_TEXT(name, text) text,
    FOR_EACH_RESOURCE_LOAD_STATISTICS_STATEMENT_LOG_LABEL(STATEMENT_LOG_LABEL_TEXT)
#undef STATEMENT_LOG_LABEL_TEXT
};
static constexpr std::array<ASCIILiteral, resourceLoadStatisticsRelationshipQueryCount> relationshipQueries {
#define RELATIONSHIP_QUERY_TEXT(name, query) query,
    FOR_EACH_RESOURCE_LOAD_STATISTICS_RELATIONSHIP_QUERY(RELATIONSHIP_QUERY_TEXT)
#undef RELATIONSHIP_QUERY_TEXT
};
static constexpr size_t maxAdHocStatements = 1024;

constexpr auto createObservedDomain = "CREATE TABLE ObservedDomains ("
    "domainID INTEGER PRIMARY KEY, registrableDomain TEXT NOT NULL UNIQUE ON CONFLICT FAIL, lastSeen REAL NOT NULL, "
    "hadUserInteraction INTEGER NOT NULL, mostRecentUserInteractionTime REAL NOT NULL, grandfathered INTEGER NOT NULL, "
    "isPrevalent INTEGER NOT NULL, isVeryPrevalent INTEGER NOT NULL, dataRecordsRemoved INTEGER NOT NULL,"
    "timesAccessedAsFirstPartyDueToUserInteraction INTEGER NOT NULL, timesAccessedAsFirstPartyDueToStorageAccessAPI INTEGER NOT NULL,"
    "isScheduledForAllButCookieDataRemoval INTEGER NOT NULL, "
    "mostRecentWebPushInteractionTime REAL NOT NULL)"_s;

constexpr auto createTopLevelDomains = "CREATE TABLE TopLevelDomains ("
    "topLevelDomainID INTEGER PRIMARY KEY, CONSTRAINT fkDomainID FOREIGN KEY(topLevelDomainID) "
    "REFERENCES ObservedDomains(domainID) ON DELETE CASCADE)"_s;

constexpr auto createStorageAccessUnderTopFrameDomains = "CREATE TABLE StorageAccessUnderTopFrameDomains ("
    "domainID INTEGER NOT NULL, topLevelDomainID INTEGER NOT NULL ON CONFLICT FAIL, "
    "CONSTRAINT fkDomainID FOREIGN KEY(domainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE, "
    "FOREIGN KEY(topLevelDomainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE)"_s;

constexpr auto createTopFrameUniqueRedirectsTo = "CREATE TABLE TopFrameUniqueRedirectsTo ("
    "sourceDomainID INTEGER NOT NULL, toDomainID INTEGER NOT NULL, "
    "FOREIGN KEY(sourceDomainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE, "
    "FOREIGN KEY(toDomainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE)"_s;

constexpr auto createTopFrameUniqueRedirectsToSinceSameSiteStrictEnforcement = "CREATE TABLE TopFrameUniqueRedirectsToSinceSameSiteStrictEnforcement ("
    "sourceDomainID INTEGER NOT NULL, toDomainID INTEGER NOT NULL, "
    "FOREIGN KEY(sourceDomainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE, "
    "FOREIGN KEY(toDomainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE)"_s;

constexpr auto createTopFrameUniqueRedirectsFrom = "CREATE TABLE TopFrameUniqueRedirectsFrom ("
    "targetDomainID INTEGER NOT NULL, fromDomainID INTEGER NOT NULL, "
    "FOREIGN KEY(targetDomainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE, "
    "FOREIGN KEY(fromDomainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE)"_s;

constexpr auto createTopFrameLinkDecorationsFrom = "CREATE TABLE TopFrameLinkDecorationsFrom ("
    "toDomainID INTEGER NOT NULL, lastUpdated REAL NOT NULL, fromDomainID INTEGER NOT NULL, "
    "FOREIGN KEY(toDomainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE, "
    "FOREIGN KEY(fromDomainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE)"_s;

constexpr auto createTopFrameLoadedThirdPartyScripts = "CREATE TABLE TopFrameLoadedThirdPartyScripts ("
    "topFrameDomainID INTEGER NOT NULL, subresourceDomainID INTEGER NOT NULL, "
    "FOREIGN KEY(topFrameDomainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE, "
    "FOREIGN KEY(subresourceDomainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE)"_s;

constexpr auto createSubframeUnderTopFrameDomains = "CREATE TABLE SubframeUnderTopFrameDomains ("
    "subFrameDomainID INTEGER NOT NULL, lastUpdated REAL NOT NULL, topFrameDomainID INTEGER NOT NULL, "
    "FOREIGN KEY(subFrameDomainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE, "
    "FOREIGN KEY(topFrameDomainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE)"_s;

constexpr auto createSubresourceUnderTopFrameDomains = "CREATE TABLE SubresourceUnderTopFrameDomains ("
    "subresourceDomainID INTEGER NOT NULL, lastUpdated REAL NOT NULL, topFrameDomainID INTEGER NOT NULL, "
    "FOREIGN KEY(subresourceDomainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE, "
    "FOREIGN KEY(topFrameDomainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE)"_s;

constexpr auto createSubresourceUniqueRedirectsTo = "CREATE TABLE SubresourceUniqueRedirectsTo ("
    "subresourceDomainID INTEGER NOT NULL, lastUpdated REAL NOT NULL, toDomainID INTEGER NOT NULL, "
    "FOREIGN KEY(subresourceDomainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE, "
    "FOREIGN KEY(toDomainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE)"_s;

constexpr auto createSubresourceUniqueRedirectsFrom = "CREATE TABLE SubresourceUniqueRedirectsFrom ("
    "subresourceDomainID INTEGER NOT NULL, fromDomainID INTEGER NOT NULL, "
    "FOREIGN KEY(subresourceDomainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE, "
    "FOREIGN KEY(fromDomainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE)"_s;

constexpr auto createOperatingDates = "CREATE TABLE OperatingDates ("
    "year INTEGER NOT NULL, month INTEGER NOT NULL, monthDay INTEGER NOT NULL)"_s;

// CREATE UNIQUE INDEX Queries.
constexpr auto createUniqueIndexStorageAccessUnderTopFrameDomains = "CREATE UNIQUE INDEX IF NOT EXISTS StorageAccessUnderTopFrameDomains_domainID_topLevelDomainID on StorageAccessUnderTopFrameDomains ( domainID, topLevelDomainID )"_s;
constexpr auto createUniqueIndexTopFrameUniqueRedirectsTo = "CREATE UNIQUE INDEX IF NOT EXISTS TopFrameUniqueRedirectsTo_sourceDomainID_toDomainID on TopFrameUniqueRedirectsTo ( sourceDomainID, toDomainID )"_s;
constexpr auto createUniqueIndexTopFrameUniqueRedirectsToSinceSameSiteStrictEnforcement = "CREATE UNIQUE INDEX IF NOT EXISTS TopFrameUniqueRedirectsToSinceSameSiteStrictEnforcement_sourceDomainID_toDomainID on TopFrameUniqueRedirectsToSinceSameSiteStrictEnforcement ( sourceDomainID, toDomainID )"_s;
constexpr auto createUniqueIndexTopFrameUniqueRedirectsFrom = "CREATE UNIQUE INDEX IF NOT EXISTS TopFrameUniqueRedirectsFrom_targetDomainID_fromDomainID on TopFrameUniqueRedirectsFrom ( targetDomainID, fromDomainID )"_s;
constexpr auto createUniqueIndexTopFrameLinkDecorationsFrom = "CREATE UNIQUE INDEX IF NOT EXISTS TopFrameLinkDecorationsFrom_toDomainID_fromDomainID on TopFrameLinkDecorationsFrom ( toDomainID, fromDomainID )"_s;
constexpr auto createUniqueIndexTopFrameLoadedThirdPartyScripts = "CREATE UNIQUE INDEX IF NOT EXISTS TopFrameLoadedThirdPartyScripts_topFrameDomainID_subresourceDomainID on TopFrameLoadedThirdPartyScripts ( topFrameDomainID, subresourceDomainID )"_s;
constexpr auto createUniqueIndexSubframeUnderTopFrameDomains = "CREATE UNIQUE INDEX IF NOT EXISTS SubframeUnderTopFrameDomains_subFrameDomainID_topFrameDomainID on SubframeUnderTopFrameDomains ( subFrameDomainID, topFrameDomainID )"_s;
constexpr auto createUniqueIndexSubresourceUnderTopFrameDomains = "CREATE UNIQUE INDEX IF NOT EXISTS SubresourceUnderTopFrameDomains_subresourceDomainID_topFrameDomainID on SubresourceUnderTopFrameDomains ( subresourceDomainID, topFrameDomainID )"_s;
constexpr auto createUniqueIndexSubresourceUniqueRedirectsTo = "CREATE UNIQUE INDEX IF NOT EXISTS SubresourceUniqueRedirectsTo_subresourceDomainID_toDomainID on SubresourceUniqueRedirectsTo ( subresourceDomainID, toDomainID )"_s;
constexpr auto createUniqueIndexSubresourceUniqueRedirectsFrom = "CREATE UNIQUE INDEX IF NOT EXISTS SubresourceUniqueRedirectsFrom_subresourceDomainID_fromDomainID on SubresourceUniqueRedirectsFrom ( subresourceDomainID, fromDomainID )"_s;
constexpr auto createUniqueIndexOperatingDates = "CREATE UNIQUE INDEX IF NOT EXISTS OperatingDates_year_month_monthDay on OperatingDates ( year, month, monthDay )"_s;

static String domainsToString(const RegistrableDomainsToDeleteOrRestrictWebsiteDataFor& domainsToRemoveOrRestrictWebsiteDataFor)
{
    StringBuilder builder;
    for (auto& domain : borrow(domainsToRemoveOrRestrictWebsiteDataFor.domainsToDeleteAllCookiesFor))
        builder.append(builder.isEmpty() ? ""_s : ", "_s, domain.string(), "(all data)"_s);
    for (auto& domain : borrow(domainsToRemoveOrRestrictWebsiteDataFor.domainsToDeleteAllButHttpOnlyCookiesFor))
        builder.append(builder.isEmpty() ? ""_s : ", "_s, domain.string(), "(all but HttpOnly cookies)"_s);
    for (auto& domain : borrow(domainsToRemoveOrRestrictWebsiteDataFor.domainsToDeleteAllScriptWrittenStorageFor))
        builder.append(builder.isEmpty() ? ""_s : ", "_s, domain.string(), "(all but cookies)"_s);
    return builder.toString();
}

static bool needsNewCreateTableSchema(const String& schema)
{
    return schema.contains("REFERENCES TopLevelDomains"_s);
}

static WallTime nowTime(Seconds timeAdvanceForTesting)
{
    return WallTime::now() + timeAdvanceForTesting;
}

OperatingDate OperatingDate::fromWallTime(WallTime time)
{
    double ms = time.secondsSinceEpoch().milliseconds();
    int year = msToYear(ms);
    int yearDay = dayInYear(ms, year);
    int month = monthFromDayInYear(yearDay, isLeapYear(year));
    int monthDay = dayInMonthFromDayInYear(yearDay, isLeapYear(year));
    return OperatingDate { year, month, monthDay };
}

OperatingDate OperatingDate::today(Seconds timeAdvanceForTesting)
{
    return OperatingDate::fromWallTime(nowTime(timeAdvanceForTesting));
}

Seconds OperatingDate::secondsSinceEpoch() const
{
    return Seconds { dateToDaysFrom1970(m_year, m_month, m_monthDay) * secondsPerDay };
}

NODELETE static WeakHashSet<ResourceLoadStatisticsStore>& allStores()
{
    ASSERT_WITH_SECURITY_IMPLICATION(!RunLoop::isMain());

    static NeverDestroyed<WeakHashSet<ResourceLoadStatisticsStore>> map;
    return map;
}

WTF_MAKE_TZONE_ALLOCATED_IMPL(ResourceLoadStatisticsStore);

ResourceLoadStatisticsStore::ResourceLoadStatisticsStore(WebResourceLoadStatisticsStore& store, SuspendableWorkQueue& workQueue, ShouldIncludeLocalhost shouldIncludeLocalhost, const String& storageDirectoryPath, PAL::SessionID sessionID)
    : DatabaseUtilities(FileSystem::pathByAppendingComponent(storageDirectoryPath, "observations.db"_s))
    , m_store(store)
    , m_workQueue(workQueue)
    , m_sessionID(sessionID)
    , m_shouldIncludeLocalhost(shouldIncludeLocalhost)
{
    ASSERT_WITH_SECURITY_IMPLICATION(!RunLoop::isMain());

    openAndUpdateSchemaIfNecessary();
    enableForeignKeys();

    if (!m_database->turnOnIncrementalAutoVacuum())
        ITP_RELEASE_LOG_DATABASE_ERROR("ResourceLoadStatisticsStore: failed to turn on auto vacuum");

    includeTodayAsOperatingDateIfNecessary();
    allStores().add(*this);
}

ResourceLoadStatisticsStore::~ResourceLoadStatisticsStore()
{
    ASSERT_WITH_SECURITY_IMPLICATION(!RunLoop::isMain());
    close();
    allStores().remove(*this);
}

void ResourceLoadStatisticsStore::openITPDatabase()
{
    m_isNewResourceLoadStatisticsDatabaseFile = openDatabaseAndCreateSchemaIfNecessary() == CreatedNewFile::Yes;
}

void ResourceLoadStatisticsStore::removeDataRecords(CompletionHandler<void()>&& completionHandler)
{
    ASSERT(!RunLoop::isMain());

    if (!shouldRemoveDataRecords()) {
        completionHandler();
        return;
    }

    auto domainsToDeleteOrRestrictWebsiteDataFor = registrableDomainsToDeleteOrRestrictWebsiteDataFor();
    if (domainsToDeleteOrRestrictWebsiteDataFor.isEmpty()) {
        completionHandler();
        return;
    }

    if (m_debugLoggingEnabled) [[unlikely]] {
        ITP_DEBUG_MODE_RELEASE_LOG("About to remove data records for %" PUBLIC_LOG_STRING ".", domainsToString(domainsToDeleteOrRestrictWebsiteDataFor).utf8());
        debugBroadcastConsoleMessage(MessageSource::ITPDebug, MessageLevel::Info, makeString("[ITP] About to remove data records for: ["_s, domainsToString(domainsToDeleteOrRestrictWebsiteDataFor), "]."_s));
    }

    setDataRecordsBeingRemoved(true);

    RunLoop::mainSingleton().dispatch([store = Ref { m_store.get() }, domainsToDeleteOrRestrictWebsiteDataFor = crossThreadCopy(WTF::move(domainsToDeleteOrRestrictWebsiteDataFor)), completionHandler = WTF::move(completionHandler), weakThis = WeakPtr { *this }, workQueue = m_workQueue] () mutable {
        store->deleteAndRestrictWebsiteDataForRegistrableDomains(WebResourceLoadStatisticsStore::monitoredDataTypes(), WTF::move(domainsToDeleteOrRestrictWebsiteDataFor), [completionHandler = WTF::move(completionHandler), weakThis = WTF::move(weakThis), workQueue](HashSet<RegistrableDomain>&& domainsWithDeletedWebsiteData) mutable {
            workQueue->dispatch([domainsWithDeletedWebsiteData = crossThreadCopy(WTF::move(domainsWithDeletedWebsiteData)), completionHandler = WTF::move(completionHandler), weakThis = WTF::move(weakThis)] () mutable {
                RefPtr protectedThis = weakThis;
                if (!protectedThis) {
                    completionHandler();
                    return;
                }

                protectedThis->incrementRecordsDeletedCountForDomains(WTF::move(domainsWithDeletedWebsiteData));
                protectedThis->setDataRecordsBeingRemoved(false);

                auto dataRecordRemovalCompletionHandlers = WTF::move(protectedThis->m_dataRecordRemovalCompletionHandlers);
                completionHandler();

                for (auto& dataRecordRemovalCompletionHandler : borrow(dataRecordRemovalCompletionHandlers))
                    dataRecordRemovalCompletionHandler();

                if (protectedThis->m_debugLoggingEnabled) [[unlikely]] {
                    ITP_DEBUG_MODE_RELEASE_LOG("Done removing data records.");
                    protectedThis->debugBroadcastConsoleMessage(MessageSource::ITPDebug, MessageLevel::Info, "[ITP] Done removing data records"_s);
                }
            });
        });
    });
}

void ResourceLoadStatisticsStore::processStatisticsAndDataRecords(CompletionHandler<void()>&& completionHandler)
{
    ASSERT(!RunLoop::isMain());

    if (m_parameters.shouldClassifyResourcesBeforeDataRecordsRemoval)
        classifyPrevalentResources();
    
    removeDataRecords([weakThis = WeakPtr { *this }, completionHandler = WTF::move(completionHandler)] () mutable {
        ASSERT(!RunLoop::isMain());
        RefPtr protectedThis = weakThis;
        if (!protectedThis) {
            completionHandler();
            return;
        }

        protectedThis->pruneStatisticsIfNeeded();

        protectedThis->logTestingEvent("Storage Synced"_s);
        completionHandler();
    });
}

std::optional<HashMap<RegistrableDomain, WallTime>> ResourceLoadStatisticsStore::loadWebsitesWithUserInteraction()
{
    ASSERT(!RunLoop::isMain());

    HashMap<RegistrableDomain, WallTime> results;
    auto statement = m_database->prepareStatement(domainWithUserInteractionQuery);
    if (!statement)
        return std::nullopt;

    while (statement->step() == SQLITE_ROW)
        results.set(RegistrableDomain::uncheckedCreateFromRegistrableDomainString(statement->columnText(0)), WallTime::fromRawSeconds(statement->columnDouble(1)));

    return results;
}

void ResourceLoadStatisticsStore::grandfatherExistingWebsiteData(CompletionHandler<void()>&& callback)
{
    ASSERT(!RunLoop::isMain());

    RunLoop::mainSingleton().dispatch([weakThis = WeakPtr { *this }, callback = WTF::move(callback), workQueue = m_workQueue, store = Ref { m_store.get() }] () mutable {
        store->registrableDomainsWithWebsiteData(WebResourceLoadStatisticsStore::monitoredDataTypes(), [weakThis = WTF::move(weakThis), callback = WTF::move(callback), workQueue] (HashSet<RegistrableDomain>&& domainsWithWebsiteData) mutable {
            workQueue->dispatch([weakThis = WTF::move(weakThis), domainsWithWebsiteData = crossThreadCopy(WTF::move(domainsWithWebsiteData)), callback = WTF::move(callback)] () mutable {
                RefPtr protectedThis = weakThis;
                if (!protectedThis) {
                    callback();
                    return;
                }

                protectedThis->grandfatherDataForDomains(domainsWithWebsiteData);
                protectedThis->m_endOfGrandfatheringTimestamp = nowTime(protectedThis->m_timeAdvanceForTesting) + protectedThis->m_parameters.grandfatheringTime;
                callback();
                protectedThis->logTestingEvent("Grandfathered"_s);
            });
        });
    });
}

#if ENABLE(APP_BOUND_DOMAINS)
void ResourceLoadStatisticsStore::setAppBoundDomains(HashSet<RegistrableDomain>&& domains)
{
    m_appBoundDomains = WTF::move(domains);
}
#endif

#if ENABLE(MANAGED_DOMAINS)
void ResourceLoadStatisticsStore::setManagedDomains(HashSet<RegistrableDomain>&& domains)
{
    m_managedDomains = WTF::move(domains);
}
#endif

void ResourceLoadStatisticsStore::scheduleStatisticsProcessingRequestIfNecessary()
{
    ASSERT(!RunLoop::isMain());

    m_pendingStatisticsProcessingRequestIdentifier = ++m_lastStatisticsProcessingRequestIdentifier;
    m_workQueue->dispatchAfter(minimumStatisticsProcessingInterval, [weakThis = WeakPtr { *this }, statisticsProcessingRequestIdentifier = *m_pendingStatisticsProcessingRequestIdentifier] {
        RefPtr protectedThis = weakThis;
        if (!protectedThis)
            return;

        if (!protectedThis->m_pendingStatisticsProcessingRequestIdentifier || *protectedThis->m_pendingStatisticsProcessingRequestIdentifier != statisticsProcessingRequestIdentifier) {
            // This request has been canceled.
            return;
        }

        protectedThis->updateCookieBlocking([]() { });
        protectedThis->processStatisticsAndDataRecords([]() { });
    });
}

void ResourceLoadStatisticsStore::cancelPendingStatisticsProcessingRequest()
{
    ASSERT(!RunLoop::isMain());

    m_pendingStatisticsProcessingRequestIdentifier = std::nullopt;
}

void ResourceLoadStatisticsStore::setTimeToLiveUserInteraction(Seconds seconds)
{
    ASSERT(!RunLoop::isMain());
    ASSERT(seconds >= 0_s);

    m_parameters.timeToLiveUserInteraction = seconds;
}

void ResourceLoadStatisticsStore::updateCacheMaxAgeCap()
{
    ASSERT(!RunLoop::isMain());
    
    RunLoop::mainSingleton().dispatch([store = Ref { m_store.get() }, seconds = m_parameters.cacheMaxAgeCapTime] () {
        store->setCacheMaxAgeCap(seconds, [] { });
    });
}

void ResourceLoadStatisticsStore::updateClientSideCookiesAgeCap()
{
    ASSERT(!RunLoop::isMain());

    Seconds capTime;
#if ENABLE(JS_COOKIE_CHECKING)
    capTime = m_parameters.clientSideCookiesForLinkDecorationTargetPageAgeCapTime;
#else
    capTime = m_parameters.clientSideCookiesAgeCapTime;
#endif

    RunLoop::mainSingleton().dispatch([store = Ref { m_store.get() }, seconds = capTime] () {
        if (CheckedPtr networkSession = store->networkSession()) {
            if (CheckedPtr storageSession = networkSession->networkStorageSession())
                storageSession->setAgeCapForClientSideCookies(seconds);
        }
    });
}

void ResourceLoadStatisticsStore::updateCookieBlockingForDomains(RegistrableDomainsToBlockCookiesFor&& domainsToBlock, CompletionHandler<void()>&& completionHandler)
{
    ASSERT(!RunLoop::isMain());
    
    RunLoop::mainSingleton().dispatch([store = Ref { m_store.get() }, domainsToBlock = crossThreadCopy(WTF::move(domainsToBlock)), completionHandler = WTF::move(completionHandler)] () mutable {
        store->callUpdatePrevalentDomainsToBlockCookiesForHandler(domainsToBlock, [store, completionHandler = WTF::move(completionHandler)]() mutable {
            store->statisticsQueue().dispatch([completionHandler = WTF::move(completionHandler)]() mutable {
                completionHandler();
            });
        });
    });
}

void ResourceLoadStatisticsStore::resetParametersToDefaultValues()
{
    ASSERT_WITH_SECURITY_IMPLICATION(!RunLoop::isMain());

    m_parameters = { };
    m_appBoundDomains.clear();
    m_timeAdvanceForTesting = { };
    m_operatingDatesSize = 0;
    m_shortWindowOperatingDate = std::nullopt;
    m_longWindowOperatingDate = std::nullopt;
    m_lastTimeDataRecordsWereRemoved = { };
}

void ResourceLoadStatisticsStore::logTestingEvent(String&& event)
{
    ASSERT(!RunLoop::isMain());

    RunLoop::mainSingleton().dispatch([store = Ref { m_store.get() }, event = WTF::move(event).isolatedCopy()] {
        store->logTestingEvent(event);
    });
}

void ResourceLoadStatisticsStore::removeAllStorageAccess(CompletionHandler<void()>&& completionHandler)
{
    ASSERT(!RunLoop::isMain());
    RunLoop::mainSingleton().dispatch([store = Ref { m_store.get() }, completionHandler = WTF::move(completionHandler)]() mutable {
        store->removeAllStorageAccess([store, completionHandler = WTF::move(completionHandler)]() mutable {
            store->statisticsQueue().dispatch([completionHandler = WTF::move(completionHandler)]() mutable {
                completionHandler();
            });
        });
    });
}

void ResourceLoadStatisticsStore::didCreateNetworkProcess()
{
    ASSERT(!RunLoop::isMain());

    updateCookieBlocking([]() { });
    updateCacheMaxAgeCap();
    updateClientSideCookiesAgeCap();
}

void ResourceLoadStatisticsStore::debugBroadcastConsoleMessage(MessageSource source, MessageLevel level, const String& message)
{
    if (!RunLoop::isMain()) {
        RunLoop::mainSingleton().dispatch([store = Ref { store() }, source = crossThreadCopy(source), level = crossThreadCopy(level), message = crossThreadCopy(message)]() {
            if (CheckedPtr networkSession = store->networkSession())
                networkSession->networkProcess().broadcastConsoleMessage(networkSession->sessionID(), source, level, message);
        });
        return;
    }

    if (CheckedPtr networkSession = m_store->networkSession())
        networkSession->networkProcess().broadcastConsoleMessage(networkSession->sessionID(), source, level, message);
}

bool ResourceLoadStatisticsStore::shouldExemptFromWebsiteDataDeletion(const RegistrableDomain& domain) const
{
    return !domain.isEmpty() && domainsExemptFromWebsiteDataDeletion().contains(domain);
}

HashSet<RegistrableDomain> ResourceLoadStatisticsStore::domainsExemptFromWebsiteDataDeletion() const
{
    auto result = m_appBoundDomains.unionWith(m_managedDomains);
    result = result.unionWith(m_persistedDomains);

    if (!m_standaloneApplicationDomain.isEmpty())
        result.add(m_standaloneApplicationDomain);

    return result;
}

const MemoryCompactLookupOnlyRobinHoodHashMap<String, TableAndIndexPair>& ResourceLoadStatisticsStore::expectedTableAndIndexQueries()
{
    static NeverDestroyed expectedTableAndIndexQueries = MemoryCompactLookupOnlyRobinHoodHashMap<String, TableAndIndexPair> {
        { "ObservedDomains"_s, std::make_pair<String, std::optional<String>>(createObservedDomain, std::nullopt) },
        { "TopLevelDomains"_s, std::make_pair<String, std::optional<String>>(createTopLevelDomains, std::nullopt) },
        { "StorageAccessUnderTopFrameDomains"_s, std::make_pair<String, std::optional<String>>(createStorageAccessUnderTopFrameDomains, stripIndexQueryToMatchStoredValue(createUniqueIndexStorageAccessUnderTopFrameDomains)) },
        { "TopFrameUniqueRedirectsTo"_s, std::make_pair<String, std::optional<String>>(createTopFrameUniqueRedirectsTo, stripIndexQueryToMatchStoredValue(createUniqueIndexTopFrameUniqueRedirectsTo)) },
        { "TopFrameUniqueRedirectsToSinceSameSiteStrictEnforcement"_s, std::make_pair<String, std::optional<String>>(createTopFrameUniqueRedirectsToSinceSameSiteStrictEnforcement, stripIndexQueryToMatchStoredValue(createUniqueIndexTopFrameUniqueRedirectsToSinceSameSiteStrictEnforcement)) },
        { "TopFrameUniqueRedirectsFrom"_s, std::make_pair<String, std::optional<String>>(createTopFrameUniqueRedirectsFrom, stripIndexQueryToMatchStoredValue(createUniqueIndexTopFrameUniqueRedirectsFrom)) },
        { "TopFrameLinkDecorationsFrom"_s, std::make_pair<String, std::optional<String>>(createTopFrameLinkDecorationsFrom, stripIndexQueryToMatchStoredValue(createUniqueIndexTopFrameLinkDecorationsFrom)) },
        { "TopFrameLoadedThirdPartyScripts"_s, std::make_pair<String, std::optional<String>>(createTopFrameLoadedThirdPartyScripts, stripIndexQueryToMatchStoredValue(createUniqueIndexTopFrameLoadedThirdPartyScripts)) },
        { "SubframeUnderTopFrameDomains"_s, std::make_pair<String, std::optional<String>>(createSubframeUnderTopFrameDomains, stripIndexQueryToMatchStoredValue(createUniqueIndexSubframeUnderTopFrameDomains)) },
        { "SubresourceUnderTopFrameDomains"_s, std::make_pair<String, std::optional<String>>(createSubresourceUnderTopFrameDomains, stripIndexQueryToMatchStoredValue(createUniqueIndexSubresourceUnderTopFrameDomains)) },
        { "SubresourceUniqueRedirectsTo"_s, std::make_pair<String, std::optional<String>>(createSubresourceUniqueRedirectsTo, stripIndexQueryToMatchStoredValue(createUniqueIndexSubresourceUniqueRedirectsTo)) },
        { "SubresourceUniqueRedirectsFrom"_s, std::make_pair<String, std::optional<String>>(createSubresourceUniqueRedirectsFrom, stripIndexQueryToMatchStoredValue(createUniqueIndexSubresourceUniqueRedirectsFrom)) },
        { "OperatingDates"_s, std::make_pair<String, std::optional<String>>(createOperatingDates, stripIndexQueryToMatchStoredValue(createUniqueIndexOperatingDates)) },
    };
    return expectedTableAndIndexQueries;
}

std::span<const ASCIILiteral> ResourceLoadStatisticsStore::sortedTables()
{
    static constexpr std::array sortedTables {
        "ObservedDomains"_s,
        "TopLevelDomains"_s,
        "StorageAccessUnderTopFrameDomains"_s,
        "TopFrameUniqueRedirectsTo"_s,
        "TopFrameUniqueRedirectsToSinceSameSiteStrictEnforcement"_s,
        "TopFrameUniqueRedirectsFrom"_s,
        "TopFrameLinkDecorationsFrom"_s,
        "TopFrameLoadedThirdPartyScripts"_s,
        "SubframeUnderTopFrameDomains"_s,
        "SubresourceUnderTopFrameDomains"_s,
        "SubresourceUniqueRedirectsTo"_s,
        "SubresourceUniqueRedirectsFrom"_s,
        "OperatingDates"_s
    };

    return sortedTables;
}

std::optional<Vector<String>> ResourceLoadStatisticsStore::checkForMissingTablesInSchema()
{
    Vector<String> missingTables;
    for (auto& table : expectedTableAndIndexQueries().keys()) {
        if (!this->tableExists(table))
            missingTables.append(String(table));
    }
    if (missingTables.isEmpty())
        return std::nullopt;

    return missingTables;
}

void ResourceLoadStatisticsStore::deleteTable(StringView tableName)
{
    ASSERT(tableExists(tableName.toString()));
    auto dropTableQuery = m_database->prepareStatementSlow(makeString("DROP TABLE "_s, tableName));
    ASSERT(dropTableQuery);
    if (!dropTableQuery || dropTableQuery->step() != SQLITE_DONE)
        ITP_RELEASE_LOG_DATABASE_ERROR("deleteTable: failed to step statement");
}

bool ResourceLoadStatisticsStore::missingReferenceToObservedDomains()
{
    // Check a table for a reference to TopLevelDomains, a sign of the old schema.
    auto oldSchema = currentTableAndIndexQueries("TopFrameUniqueRedirectsTo"_s).first;
    return needsNewCreateTableSchema(oldSchema);
}

bool ResourceLoadStatisticsStore::needsUpdatedSchema()
{
    // There are 3 cases where we expect potential schema changes due to upgrades.
    // All other tables should be up-to-date, so we should ASSERT that they are correct.
    if (missingReferenceToObservedDomains() || missingUniqueIndices())
        return true;

    for (auto& table : expectedTableAndIndexQueries().keys()) {
        UNUSED_PARAM(table);
        ASSERT(currentTableAndIndexQueries(table) == expectedTableAndIndexQueries().get(table));
    }

    return false;
}

void ResourceLoadStatisticsStore::migrateDataToPCMDatabaseIfNecessary()
{
    if (!tableExists("UnattributedPrivateClickMeasurement"_s)
        && !tableExists("AttributedPrivateClickMeasurement"_s))
        return;

    Vector<WebCore::PrivateClickMeasurement> unattributed;
    {
        constexpr auto allUnattributedPrivateClickMeasurementAttributionsQuery = "SELECT * FROM UnattributedPrivateClickMeasurement"_s;
        auto unattributedScopedStatement = m_database->prepareStatement(allUnattributedPrivateClickMeasurementAttributionsQuery);
        if (!unattributedScopedStatement) {
            ITP_RELEASE_LOG_DATABASE_ERROR("migrateDataToPCMDatabaseIfNecessary: failed to prepare unattributedScopedStatement");
            return;
        }
        while (unattributedScopedStatement->step() == SQLITE_ROW)
            unattributed.append(buildPrivateClickMeasurementFromDatabase(*unattributedScopedStatement, PrivateClickMeasurementAttributionType::Unattributed));
    }

    Vector<WebCore::PrivateClickMeasurement> attributed;
    {
        constexpr auto allAttributedPrivateClickMeasurementQuery = "SELECT * FROM AttributedPrivateClickMeasurement"_s;
        auto attributedScopedStatement = m_database->prepareStatement(allAttributedPrivateClickMeasurementQuery);
        if (!attributedScopedStatement) {
            ITP_RELEASE_LOG_DATABASE_ERROR("migrateDataToPCMDatabaseIfNecessary: failed to prepare attributedScopedStatement");
            return;
        }
        while (attributedScopedStatement->step() == SQLITE_ROW)
            attributed.append(buildPrivateClickMeasurementFromDatabase(*attributedScopedStatement, PrivateClickMeasurementAttributionType::Attributed));
    }

    if (!unattributed.isEmpty() || !attributed.isEmpty()) {
        RunLoop::mainSingleton().dispatch([store = Ref { store() }, unattributed = crossThreadCopy(WTF::move(unattributed)), attributed = crossThreadCopy(WTF::move(attributed))] () mutable {
            CheckedPtr networkSession = store->networkSession();
            if (!networkSession)
                return;

            Ref manager = networkSession->privateClickMeasurement();
            for (auto&& pcm : borrow(attributed))
                manager->migratePrivateClickMeasurementFromLegacyStorage(WTF::move(pcm), PrivateClickMeasurementAttributionType::Attributed);
            for (auto&& pcm : borrow(unattributed))
                manager->migratePrivateClickMeasurementFromLegacyStorage(WTF::move(pcm), PrivateClickMeasurementAttributionType::Unattributed);
        });

    }

    auto transactionScope = beginTransactionIfNecessary();
    deleteTable("UnattributedPrivateClickMeasurement"_s);
    deleteTable("AttributedPrivateClickMeasurement"_s);
}

void ResourceLoadStatisticsStore::addMissingTablesIfNecessary()
{
    const auto missingTables = checkForMissingTablesInSchema();
    if (!missingTables)
        return;

    auto transaction = beginTransactionIfNecessary();

    for (auto& table : *missingTables) {
        auto createTableQuery = expectedTableAndIndexQueries().get(table).first;
        if (!m_database->executeCommandSlow(createTableQuery))
            ITP_RELEASE_LOG_DATABASE_ERROR("addMissingTablesIfNecessary: failed to execute statement");
    }

    if (!createUniqueIndices())
        ITP_RELEASE_LOG_ERROR("addMissingTablesIfNecessary: failed to create unique indices");
}

template<typename T, typename U, size_t size> NODELETE bool vectorEqualsArray(const Vector<T>& vector, const std::array<U, size> array)
{
    if (vector.size() != size)
        return false;
    for (size_t i = 0; i < size; i++) {
        if (vector[i] != array[i])
            return false;
    }
    return true;
}

void ResourceLoadStatisticsStore::openAndUpdateSchemaIfNecessary()
{
    openITPDatabase();
    addMissingTablesIfNecessary();

    auto columns = columnsForTable("ObservedDomains"_s);

    std::array<ASCIILiteral, 12> columnsWithoutMostRecentWebPushInteractionTime {
        "domainID"_s,
        "registrableDomain"_s,
        "lastSeen"_s,
        "hadUserInteraction"_s,
        "mostRecentUserInteractionTime"_s,
        "grandfathered"_s,
        "isPrevalent"_s,
        "isVeryPrevalent"_s,
        "dataRecordsRemoved"_s,
        "timesAccessedAsFirstPartyDueToUserInteraction"_s,
        "timesAccessedAsFirstPartyDueToStorageAccessAPI"_s,
        "isScheduledForAllButCookieDataRemoval"_s
    };

    if (vectorEqualsArray<String, ASCIILiteral, 12>(columns, columnsWithoutMostRecentWebPushInteractionTime)
        && addMissingColumnToTable("ObservedDomains"_s, "mostRecentWebPushInteractionTime REAL DEFAULT 0.0 NOT NULL"_s))
        columns.append("mostRecentWebPushInteractionTime"_s);

    std::array<ASCIILiteral, 13> currentSchemaColumns {
        "domainID"_s,
        "registrableDomain"_s,
        "lastSeen"_s,
        "hadUserInteraction"_s,
        "mostRecentUserInteractionTime"_s,
        "grandfathered"_s,
        "isPrevalent"_s,
        "isVeryPrevalent"_s,
        "dataRecordsRemoved"_s,
        "timesAccessedAsFirstPartyDueToUserInteraction"_s,
        "timesAccessedAsFirstPartyDueToStorageAccessAPI"_s,
        "isScheduledForAllButCookieDataRemoval"_s,
        "mostRecentWebPushInteractionTime"_s
    };

    if (!vectorEqualsArray<String, ASCIILiteral, 13>(columns, currentSchemaColumns)) {
        close();
        ITP_RELEASE_LOG_ERROR("openAndUpdateSchemaIfNecessary: failed at scheme check, will create new database");
        FileSystem::deleteFile(m_storageFilePath);
        openITPDatabase();
        return;
    }

    migrateDataToPCMDatabaseIfNecessary();
    migrateDataToNewTablesIfNecessary();
}

void ResourceLoadStatisticsStore::interruptAllDatabases()
{
    ASSERT_WITH_SECURITY_IMPLICATION(!RunLoop::isMain());
    for (Ref store : allStores())
        store->interrupt();
}

bool ResourceLoadStatisticsStore::createUniqueIndices()
{
    static constexpr std::array uniqueIndexQueries {
        createUniqueIndexStorageAccessUnderTopFrameDomains,
        createUniqueIndexTopFrameUniqueRedirectsTo,
        createUniqueIndexTopFrameUniqueRedirectsToSinceSameSiteStrictEnforcement,
        createUniqueIndexTopFrameUniqueRedirectsFrom,
        createUniqueIndexTopFrameLinkDecorationsFrom,
        createUniqueIndexTopFrameLoadedThirdPartyScripts,
        createUniqueIndexSubframeUnderTopFrameDomains,
        createUniqueIndexSubresourceUnderTopFrameDomains,
        createUniqueIndexSubresourceUniqueRedirectsTo,
        createUniqueIndexSubresourceUniqueRedirectsFrom,
        createUniqueIndexSubresourceUnderTopFrameDomains,
        createUniqueIndexOperatingDates,
    };
    static_assert(uniqueIndexQueries.size() + 1 == expectedIndexCount());
    static_assert([] {
        size_t placeholders = 0;
        for (char character : insertObservedDomainQuery.span())
            placeholders += character == '?';
        return placeholders;
    }() == static_cast<size_t>(ObservedDomainsColumn::MostRecentWebPushInteractionTime));

    for (auto query : uniqueIndexQueries) {
        if (!m_database->executeCommand(query)) {
            ITP_RELEASE_LOG_DATABASE_ERROR("createUniqueIndices: failed to execute statement");
            return false;
        }
    }
    return true;
}

bool ResourceLoadStatisticsStore::createSchema()
{
    ASSERT(!RunLoop::isMain());

    if (!m_database->executeCommand(createObservedDomain)) {
        ITP_RELEASE_LOG_DATABASE_ERROR("createSchema: failed to execute statement createObservedDomain");
        return false;
    }

    // FIXME: drop TopLevelDomains table as it is not used.
    if (!m_database->executeCommand(createTopLevelDomains)) {
        ITP_RELEASE_LOG_DATABASE_ERROR("createSchema: failed to execute statement createTopLevelDomains");
        return false;
    }

    if (!m_database->executeCommand(createStorageAccessUnderTopFrameDomains)) {
        ITP_RELEASE_LOG_DATABASE_ERROR("createSchema: failed to execute statement createStorageAccessUnderTopFrameDomains");
        return false;
    }

    if (!m_database->executeCommand(createTopFrameUniqueRedirectsTo)) {
        ITP_RELEASE_LOG_DATABASE_ERROR("createSchema: failed to execute statement createTopFrameUniqueRedirectsTo");
        return false;
    }

    if (!m_database->executeCommand(createTopFrameUniqueRedirectsToSinceSameSiteStrictEnforcement)) {
        ITP_RELEASE_LOG_DATABASE_ERROR("createSchema: failed to execute statement createTopFrameUniqueRedirectsToSinceSameSiteStrictEnforcement");
        return false;
    }

    if (!m_database->executeCommand(createTopFrameUniqueRedirectsFrom)) {
        ITP_RELEASE_LOG_DATABASE_ERROR("createSchema: failed to execute statement createTopFrameUniqueRedirectsFrom");
        return false;
    }

    if (!m_database->executeCommand(createTopFrameLinkDecorationsFrom)) {
        ITP_RELEASE_LOG_DATABASE_ERROR("createSchema: failed to execute statement createTopFrameLinkDecorationsFrom");
        return false;
    }

    if (!m_database->executeCommand(createTopFrameLoadedThirdPartyScripts)) {
        ITP_RELEASE_LOG_DATABASE_ERROR("createSchema: failed to execute statement createTopFrameLoadedThirdPartyScripts");
        return false;
    }

    if (!m_database->executeCommand(createSubframeUnderTopFrameDomains)) {
        ITP_RELEASE_LOG_DATABASE_ERROR("createSchema: failed to execute statement createSubframeUnderTopFrameDomains");
        return false;
    }

    if (!m_database->executeCommand(createSubresourceUnderTopFrameDomains)) {
        ITP_RELEASE_LOG_DATABASE_ERROR("createSchema: failed to execute statement createSubresourceUnderTopFrameDomains");
        return false;
    }

    if (!m_database->executeCommand(createSubresourceUniqueRedirectsTo)) {
        ITP_RELEASE_LOG_DATABASE_ERROR("createSchema: failed to execute statement createSubresourceUniqueRedirectsTo");
        return false;
    }

    if (!m_database->executeCommand(createSubresourceUniqueRedirectsFrom)) {
        ITP_RELEASE_LOG_DATABASE_ERROR("createSchema: failed to execute statement createSubresourceUniqueRedirectsFrom");
        return false;
    }

    if (!m_database->executeCommand(createOperatingDates)) {
        ITP_RELEASE_LOG_DATABASE_ERROR("createSchema: failed to execute statement createOperatingDates");
        return false;
    }

    if (!createUniqueIndices())
        return false;

    return true;
}

static void retireGeneration(uint64_t& generation)
{
    RELEASE_ASSERT(generation < std::numeric_limits<uint64_t>::max());
    ++generation;
}

bool ResourceLoadStatisticsStore::beginTransactionIfNecessaryForSwift()
{
    ASSERT(!RunLoop::isMain());
    if (m_transaction.inProgress())
        return false;

    m_transaction.begin();
    return true;
}

void ResourceLoadStatisticsStore::commitTransactionForSwift(bool didBeginTransaction)
{
    if (didBeginTransaction)
        m_transaction.commit();
}

DomainIDVector ResourceLoadStatisticsStore::hashMapIterationOrder(DomainIDVector keys)
{
    HashMap<unsigned, unsigned> indexes;
    for (unsigned index = 0; index < keys.size(); ++index)
        indexes.add(keys[index], index);
    return copyToVector(indexes.values());
}

void ResourceLoadStatisticsStore::destroyStatements()
{
    ASSERT_WITH_SECURITY_IMPLICATION(!RunLoop::isMain());

    for (auto& slot : m_statements) {
        slot.statement = nullptr;
        retireGeneration(slot.generation);
    }
}

// No member below keeps a reference to a StatementSlot across a call that can reach these members again, since
// m_statements can grow and move its slots. SQLite calls back only into the database's busy handler and
// unauthorized-function hook, neither of which reaches the store.
static SQLiteStatement& resolveStatement(auto& slots, uint32_t index, uint64_t generation)
{
    RELEASE_ASSERT(index < slots.size());
    auto& slot = slots[index];
    RELEASE_ASSERT(slot.statement && slot.generation == generation);
    return *slot.statement;
}

SQLStatementHandle ResourceLoadStatisticsStore::openCachedStatement(ResourceLoadStatisticsCachedStatement which, ResourceLoadStatisticsStatementLogLabel logLabel) const
{
    ASSERT(!RunLoop::isMain());
    uint32_t index = std::to_underlying(which);
    uint32_t logLabelIndex = std::to_underlying(logLabel);
    // Swift can make either enum from any raw value.
    RELEASE_ASSERT(index < resourceLoadStatisticsCachedStatementCount);
    RELEASE_ASSERT(logLabelIndex < resourceLoadStatisticsStatementLogLabelCount);
    auto& slot = m_statements[index];
    if (!slot.statement) {
        slot.statement = m_database->prepareStatement(cachedStatementQueries[index]);
        if (!slot.statement) {
            RELEASE_LOG_ERROR(PrivateClickMeasurement, "%p - DatabaseUtilities::%" PUBLIC_LOG_STRING " failed to prepare statement, error message: %" PUBLIC_LOG_STRING, this, statementLogLabels[logLabelIndex].characters(), m_database->lastErrorMsg());
            return { };
        }
        ASSERT(m_database->isOpen());
    }
    return { index, slot.generation };
}

SQLStatementHandle ResourceLoadStatisticsStore::openStatement(String query) const
{
    auto statement = m_database->prepareStatementSlow(query);
    if (!statement)
        return { };
    uint32_t index = resourceLoadStatisticsCachedStatementCount;
    while (index < m_statements.size() && m_statements[index].statement)
        ++index;
    if (index == m_statements.size()) {
        RELEASE_ASSERT(index < resourceLoadStatisticsCachedStatementCount + maxAdHocStatements);
        m_statements.constructAndAppend();
    }
    m_statements[index].statement = WTF::move(statement);
    return { index, m_statements[index].generation };
}

SQLStatementHandle ResourceLoadStatisticsStore::openRelationshipStatement(ResourceLoadStatisticsRelationshipQuery query, uint32_t domainCount) const
{
    uint32_t index = std::to_underlying(query);
    // Swift can make the enum from any raw value.
    RELEASE_ASSERT(index < resourceLoadStatisticsRelationshipQueryCount);
    StringBuilder placeholders;
    for (uint32_t i = 0; i < domainCount; ++i)
        placeholders.append(i ? ", ?"_s : "?"_s);
    return openStatement(makeString(relationshipQueries[index], placeholders.toString(), " );"_s));
}

void ResourceLoadStatisticsStore::closeStatement(SQLStatementHandle handle) const
{
    // The bound test comes first: a handle can name any slot.
    if (handle.m_slot >= m_statements.size() || !m_statements[handle.m_slot].statement || m_statements[handle.m_slot].generation != handle.m_generation)
        return;
    auto& slot = m_statements[handle.m_slot];
    if (handle.m_slot < resourceLoadStatisticsCachedStatementCount) {
        slot.statement->reset();
        return;
    }
    slot.statement = nullptr;
    retireGeneration(slot.generation);
}

int ResourceLoadStatisticsStore::bindInt(SQLStatementHandle handle, int index, int value) const
{
    return resolveStatement(m_statements, handle.m_slot, handle.m_generation).bindInt(index, value);
}

int ResourceLoadStatisticsStore::bindText(SQLStatementHandle handle, int index, String value) const
{
    return resolveStatement(m_statements, handle.m_slot, handle.m_generation).bindText(index, value);
}

int ResourceLoadStatisticsStore::bindDouble(SQLStatementHandle handle, int index, double value) const
{
    return resolveStatement(m_statements, handle.m_slot, handle.m_generation).bindDouble(index, value);
}

int ResourceLoadStatisticsStore::step(SQLStatementHandle handle) const
{
    return resolveStatement(m_statements, handle.m_slot, handle.m_generation).step();
}

int ResourceLoadStatisticsStore::reset(SQLStatementHandle handle) const
{
    return resolveStatement(m_statements, handle.m_slot, handle.m_generation).reset();
}

int ResourceLoadStatisticsStore::columnInt(SQLStatementHandle handle, int column) const
{
    return resolveStatement(m_statements, handle.m_slot, handle.m_generation).columnInt(column);
}

String ResourceLoadStatisticsStore::columnText(SQLStatementHandle handle, int column) const
{
    return resolveStatement(m_statements, handle.m_slot, handle.m_generation).columnText(column);
}

double ResourceLoadStatisticsStore::columnDouble(SQLStatementHandle handle, int column) const
{
    return resolveStatement(m_statements, handle.m_slot, handle.m_generation).columnDouble(column);
}

void ResourceLoadStatisticsStore::mergeStatistics(Vector<ResourceLoadStatistics>&& statistics)
{
    ASSERT(!RunLoop::isMain());
    if (statistics.isEmpty())
        return;

    auto transactionScope = beginTransactionIfNecessary();

    Borrow borrowedStatistics = statistics;
    for (auto& statistic : borrowedStatistics) {
        if (!domainID(statistic.registrableDomain)) {
            if (!insertObservedDomainRecord(statistic.registrableDomain, statistic.lastSeen.secondsSinceEpoch().value(), statistic.hadUserInteraction, statistic.mostRecentUserInteractionTime.secondsSinceEpoch().value(), statistic.grandfathered, statistic.isPrevalentResource, statistic.isVeryPrevalentResource, statistic.dataRecordsRemoved, statistic.timesAccessedAsFirstPartyDueToUserInteraction, statistic.timesAccessedAsFirstPartyDueToStorageAccessAPI, statistic.gotLinkDecorationFromPrevalentResource)) {
                ITP_RELEASE_LOG_ERROR("mergeStatistics: failed to insert observed domain");
                return;
            }
        } else
            mergeStatistic(statistic.registrableDomain, statistic.lastSeen, statistic.hadUserInteraction, statistic.mostRecentUserInteractionTime, statistic.grandfathered, statistic.isPrevalentResource, statistic.isVeryPrevalentResource, statistic.dataRecordsRemoved, statistic.gotLinkDecorationFromPrevalentResource);
    }

    // Make a separate pass for inter-domain relationships so we
    // can refer to the ObservedDomain table entries.
    for (auto& statistic : borrowedStatistics) {
        insertDomainRelationshipsRecord(statistic.registrableDomain, copyToVector(statistic.storageAccessUnderTopFrameDomains),
            copyToVector(statistic.topFrameUniqueRedirectsTo),
            copyToVector(statistic.topFrameUniqueRedirectsToSinceSameSiteStrictEnforcement),
            copyToVector(statistic.topFrameUniqueRedirectsFrom), copyToVector(statistic.subframeUnderTopFrameDomains),
            copyToVector(statistic.subresourceUnderTopFrameDomains), copyToVector(statistic.subresourceUniqueRedirectsTo),
            copyToVector(statistic.subresourceUniqueRedirectsFrom), copyToVector(statistic.topFrameLinkDecorationsFrom),
            copyToVector(statistic.topFrameLoadedThirdPartyScripts));
    }
}

void ResourceLoadStatisticsStore::incrementRecordsDeletedCountForDomains(HashSet<RegistrableDomain>&& domains)
{
    updateObservedDomainsList("dataRecordsRemoved = dataRecordsRemoved + 1"_s, copyToVector(domains), "incrementRecordsDeletedCountForDomains"_s);
}

void ResourceLoadStatisticsStore::hasStorageAccess(SubFrameDomain&& subFrameDomain, TopFrameDomain&& topFrameDomain, std::optional<FrameIdentifier> frameID, WebPageProxyIdentifier webPageProxyID, CanRequestStorageAccessWithoutUserInteraction canRequestStorageAccessWithoutUserInteraction, CompletionHandler<void(bool)>&& completionHandler)
{
    ASSERT(!RunLoop::isMain());

    auto result = ensureResourceStatisticsForRegistrableDomain(subFrameDomain, "hasStorageAccess"_s);
    if (!result.second) {
        completionHandler(false);
        return;
    }

    switch (cookieAccess(subFrameDomain, topFrameDomain, canRequestStorageAccessWithoutUserInteraction)) {
    case CookieAccess::CannotRequest:
        completionHandler(false);
        return;
    case CookieAccess::BasedOnCookiePolicy:
        RunLoop::mainSingleton().dispatch([store = Ref { store() }, subFrameDomain = WTF::move(subFrameDomain).isolatedCopy(), completionHandler = WTF::move(completionHandler)]() mutable {
            store->hasCookies(subFrameDomain, [store, completionHandler = WTF::move(completionHandler)](bool result) mutable {
                store->statisticsQueue().dispatch([completionHandler = WTF::move(completionHandler), result] () mutable {
                    completionHandler(result);
                });
            });
        });
        return;
    case CookieAccess::OnlyIfGranted:
        // Handled below.
        break;
    };

    RunLoop::mainSingleton().dispatch([store = Ref { store() }, subFrameDomain = WTF::move(subFrameDomain).isolatedCopy(), topFrameDomain = WTF::move(topFrameDomain).isolatedCopy(), frameID, webPageProxyID, completionHandler = WTF::move(completionHandler)]() mutable {
        store->callHasStorageAccessForFrameHandler(subFrameDomain, topFrameDomain, frameID.value(), webPageProxyID, [store, completionHandler = WTF::move(completionHandler)](bool result) mutable {
            store->statisticsQueue().dispatch([completionHandler = WTF::move(completionHandler), result] () mutable {
                completionHandler(result);
            });
        });
    });
}

void ResourceLoadStatisticsStore::requestStorageAccess(SubFrameDomain&& subFrameDomain, TopFrameDomain&& topFrameDomain, FrameIdentifier frameID, WebPageProxyIdentifier webPageProxyID, StorageAccessScope scope, CanRequestStorageAccessWithoutUserInteraction canRequestStorageAccessWithoutUserInteraction, CompletionHandler<void(StorageAccessStatus)>&& completionHandler)
{
    ASSERT(!RunLoop::isMain());

    auto subFrameStatus = ensureResourceStatisticsForRegistrableDomain(subFrameDomain, "requestStorageAccess"_s);
    if (!subFrameStatus.second)
        return completionHandler(StorageAccessStatus::CannotRequestAccess);

    switch (cookieAccess(subFrameDomain, topFrameDomain, canRequestStorageAccessWithoutUserInteraction)) {
    case CookieAccess::CannotRequest:
        if (debugLoggingEnabled()) [[unlikely]] {
            ITP_DEBUG_MODE_RELEASE_LOG("Cannot grant storage access to %" PRIVATE_LOG_STRING " since its cookies are blocked in third-party contexts and it has not received user interaction as first-party.", subFrameDomain.string().utf8());
            debugBroadcastConsoleMessage(MessageSource::ITPDebug, MessageLevel::Error, makeString("[ITP] Cannot grant storage access to '"_s, subFrameDomain.string(), "' since its cookies are blocked in third-party contexts and it has not received user interaction as first-party."_s));
        }
        completionHandler(StorageAccessStatus::CannotRequestAccess);
        return;
    case CookieAccess::BasedOnCookiePolicy:
        if (debugLoggingEnabled()) [[unlikely]] {
            ITP_DEBUG_MODE_RELEASE_LOG("No need to grant storage access to %" PRIVATE_LOG_STRING " since its cookies are not blocked in third-party contexts. Note that the underlying cookie policy may still block this third-party from setting cookies.", subFrameDomain.string().utf8());
            debugBroadcastConsoleMessage(MessageSource::ITPDebug, MessageLevel::Info, makeString("[ITP] No need to grant storage access to '"_s, subFrameDomain.string(), "' since its cookies are not blocked in third-party contexts. Note that the underlying cookie policy may still block this third-party from setting cookies."_s));
        }
        completionHandler(StorageAccessStatus::HasAccess);
        return;
    case CookieAccess::OnlyIfGranted:
        // Handled below.
        break;
    }

    auto userWasPromptedEarlier = hasUserGrantedStorageAccessThroughPrompt(*subFrameStatus.second, topFrameDomain) ? StorageAccessPromptWasShown::Yes : StorageAccessPromptWasShown::No;
    if (userWasPromptedEarlier == StorageAccessPromptWasShown::No) {
        if (debugLoggingEnabled()) [[unlikely]] {
            ITP_DEBUG_MODE_RELEASE_LOG("About to ask the user whether they want to grant storage access to %" PRIVATE_LOG_STRING " under %" PRIVATE_LOG_STRING " or not.", subFrameDomain.string().utf8(), topFrameDomain.string().utf8());
            debugBroadcastConsoleMessage(MessageSource::ITPDebug, MessageLevel::Info, makeString("[ITP] About to ask the user whether they want to grant storage access to '"_s, subFrameDomain.string(), "' under '"_s, topFrameDomain.string(), "' or not."_s));
        }
        completionHandler(StorageAccessStatus::RequiresUserPrompt);
        return;
    }

    if (userWasPromptedEarlier == StorageAccessPromptWasShown::Yes) {
        if (debugLoggingEnabled()) [[unlikely]] {
            ITP_DEBUG_MODE_RELEASE_LOG("Storage access was granted to %" PRIVATE_LOG_STRING " under %" PRIVATE_LOG_STRING ".", subFrameDomain.string().utf8(), topFrameDomain.string().utf8());
            debugBroadcastConsoleMessage(MessageSource::ITPDebug, MessageLevel::Info, makeString("[ITP] Storage access was granted to '"_s, subFrameDomain.string(), "' under '"_s, topFrameDomain.string(), "'."_s));
        }
    }

    auto transactionScope = beginTransactionIfNecessary();

    auto incrementStorageAccess = m_database->prepareStatement("UPDATE ObservedDomains SET timesAccessedAsFirstPartyDueToStorageAccessAPI = timesAccessedAsFirstPartyDueToStorageAccessAPI + 1 WHERE domainID = ?"_s);
    if (!incrementStorageAccess
        || incrementStorageAccess->bindInt(1, *subFrameStatus.second) != SQLITE_OK
        || incrementStorageAccess->step() != SQLITE_DONE) {
        ITP_RELEASE_LOG_DATABASE_ERROR("requestStorageAccess: failed to step statement");
        return completionHandler(StorageAccessStatus::CannotRequestAccess);
    }

    grantStorageAccessInternal(WTF::move(subFrameDomain), WTF::move(topFrameDomain), frameID, webPageProxyID, userWasPromptedEarlier, scope, canRequestStorageAccessWithoutUserInteraction, [completionHandler = WTF::move(completionHandler)] (StorageAccessWasGranted wasGranted) mutable {
        completionHandler(wasGranted == StorageAccessWasGranted::Yes ? StorageAccessStatus::HasAccess : StorageAccessStatus::CannotRequestAccess);
    });
}

void ResourceLoadStatisticsStore::queryStorageAccessPermission(const SubFrameDomain& subFrameDomain, const TopFrameDomain& topFrameDomain, CompletionHandler<void(PermissionState)>&& completionHandler)
{
    ASSERT(!RunLoop::isMain());

    auto subFrameDomainID = domainID(subFrameDomain);
    if (!subFrameDomainID)
        return completionHandler(PermissionState::Prompt);

    if (!hasUserGrantedStorageAccessThroughPrompt(*subFrameDomainID, topFrameDomain))
        return completionHandler(PermissionState::Prompt);

    completionHandler(PermissionState::Granted);
}

void ResourceLoadStatisticsStore::requestStorageAccessUnderOpener(DomainInNeedOfStorageAccess&& domainInNeedOfStorageAccess, WebPageProxyIdentifier openerWebPageProxyID, OpenerDomain&& openerDomain, CanRequestStorageAccessWithoutUserInteraction canRequestStorageAccessWithoutUserInteraction)
{
    ASSERT(domainInNeedOfStorageAccess != openerDomain);
    ASSERT(!RunLoop::isMain());

    if (domainInNeedOfStorageAccess == openerDomain)
        return;

    if (debugLoggingEnabled()) [[unlikely]] {
        ITP_DEBUG_MODE_RELEASE_LOG("[Temporary combatibility fix] Storage access was granted for %" PRIVATE_LOG_STRING " under opener page from %" PRIVATE_LOG_STRING ", with user interaction in the opened window.", domainInNeedOfStorageAccess.string().utf8(), openerDomain.string().utf8());
        debugBroadcastConsoleMessage(MessageSource::ITPDebug, MessageLevel::Info, makeString("[ITP] Storage access was granted for '"_s, domainInNeedOfStorageAccess.string(), "' under opener page from '"_s, openerDomain.string(), "', with user interaction in the opened window."_s));
    }

    grantStorageAccessInternal(WTF::move(domainInNeedOfStorageAccess), WTF::move(openerDomain), std::nullopt, openerWebPageProxyID, StorageAccessPromptWasShown::No, StorageAccessScope::PerPage, canRequestStorageAccessWithoutUserInteraction, [](StorageAccessWasGranted) { });
}

void ResourceLoadStatisticsStore::grantStorageAccess(SubFrameDomain&& subFrameDomain, TopFrameDomain&& topFrameDomain, FrameIdentifier frameID, WebPageProxyIdentifier webPageProxyID, StorageAccessPromptWasShown promptWasShown, StorageAccessScope scope, CompletionHandler<void(StorageAccessWasGranted)>&& completionHandler)
{
    ASSERT(!RunLoop::isMain());

    auto transactionScope = beginTransactionIfNecessary();

    auto addGrant = [weakThis = WeakPtr { *this }, frameID, webPageProxyID, promptWasShown, scope] (SubFrameDomain&& subFrameDomain, TopFrameDomain&& topFrameDomain, CanRequestStorageAccessWithoutUserInteraction canRequestStorageAccessWithoutUserInteraction, CompletionHandler<void(StorageAccessWasGranted)>&& completionHandler) mutable {
        RefPtr protectedThis = weakThis;

        if (!protectedThis)
            return completionHandler(StorageAccessWasGranted::No);

        if (promptWasShown == StorageAccessPromptWasShown::Yes) {
            auto subFrameStatus = protectedThis->grantStorageAccessPermission(topFrameDomain, subFrameDomain);
            if (!subFrameStatus.second)
                return completionHandler(StorageAccessWasGranted::No);

            ASSERT(subFrameStatus.first == AddedRecord::No);
#if ASSERT_ENABLED
            if (canRequestStorageAccessWithoutUserInteraction == CanRequestStorageAccessWithoutUserInteraction::No)
                ASSERT(protectedThis->hasHadUserInteraction(subFrameDomain, OperatingDatesWindow::Long));
#endif
        }

        protectedThis->grantStorageAccessInternal(WTF::move(subFrameDomain), WTF::move(topFrameDomain), frameID, webPageProxyID, promptWasShown, scope, canRequestStorageAccessWithoutUserInteraction, WTF::move(completionHandler));
    };

    RunLoop::mainSingleton().dispatch([weakThis = WeakPtr { *this }, subFrameDomain = WTF::move(subFrameDomain).isolatedCopy(), topFrameDomain = WTF::move(topFrameDomain).isolatedCopy(), workQueue = m_workQueue, store = Ref { store() }, addGrant = WTF::move(addGrant), completionHandler = WTF::move(completionHandler)]() mutable {

        std::optional<OrganizationStorageAccessPromptQuirk> additionalDomainGrants;
        CanRequestStorageAccessWithoutUserInteraction canRequestStorageAccessWithoutUserInteraction { CanRequestStorageAccessWithoutUserInteraction::No };

        if (CheckedPtr networkSession = store->networkSession()) {
            if (networkSession->networkStorageSession()) {
                additionalDomainGrants = WebCore::storageAccessQuirkForDomainPair(subFrameDomain, topFrameDomain);
                canRequestStorageAccessWithoutUserInteraction = WebCore::canRequestStorageAccessForLoginOrCompatibilityPurposesWithoutPriorUserInteraction(subFrameDomain, topFrameDomain) ? CanRequestStorageAccessWithoutUserInteraction::Yes : CanRequestStorageAccessWithoutUserInteraction::No;
            }
        }
        workQueue->dispatch([weakThis = WTF::move(weakThis), additionalDomainGrants = crossThreadCopy(WTF::move(additionalDomainGrants)), subFrameDomain = crossThreadCopy(WTF::move(subFrameDomain)), topFrameDomain = crossThreadCopy(WTF::move(topFrameDomain)), addGrant = WTF::move(addGrant), canRequestStorageAccessWithoutUserInteraction, completionHandler = WTF::move(completionHandler)] () mutable {
            if (!weakThis) {
                completionHandler(StorageAccessWasGranted::No);
                return;
            }
            if (additionalDomainGrants) {
                for (auto&& [quirkTopFrameDomain, subFrameDomains] : additionalDomainGrants->quirkDomains) {
                    for (auto&& quirkSubFrameDomain : borrow(subFrameDomains)) {
                        if (quirkTopFrameDomain == topFrameDomain && quirkSubFrameDomain == subFrameDomain)
                            continue;
                        addGrant(SubFrameDomain { quirkSubFrameDomain }, TopFrameDomain { quirkTopFrameDomain }, canRequestStorageAccessWithoutUserInteraction, [] (StorageAccessWasGranted) { });
                    }
                }
            }
            addGrant(WTF::move(subFrameDomain), WTF::move(topFrameDomain), canRequestStorageAccessWithoutUserInteraction, WTF::move(completionHandler));
        });
    });
}

void ResourceLoadStatisticsStore::grantStorageAccessInternal(SubFrameDomain&& subFrameDomain, TopFrameDomain&& topFrameDomain, std::optional<FrameIdentifier> frameID, WebPageProxyIdentifier webPageProxyID, StorageAccessPromptWasShown promptWasShownNowOrEarlier, StorageAccessScope scope, CanRequestStorageAccessWithoutUserInteraction canRequestStorageAccessWithoutUserInteraction, CompletionHandler<void(StorageAccessWasGranted)>&& completionHandler)
{
    ASSERT(!RunLoop::isMain());

    if (subFrameDomain == topFrameDomain) {
        completionHandler(StorageAccessWasGranted::Yes);
        return;
    }

    if (promptWasShownNowOrEarlier == StorageAccessPromptWasShown::Yes) {
        auto transactionScope = beginTransactionIfNecessary();
#ifndef NDEBUG
        auto subFrameStatus = ensureResourceStatisticsForRegistrableDomain(subFrameDomain, "grantStorageAccessInternal"_s);
        if (!subFrameStatus.second)
            return;

        ASSERT(subFrameStatus.first == AddedRecord::No);
#if ASSERT_ENABLED
        if (canRequestStorageAccessWithoutUserInteraction == CanRequestStorageAccessWithoutUserInteraction::No)
            ASSERT(hasHadUserInteraction(subFrameDomain, OperatingDatesWindow::Long));
#endif
        ASSERT(hasUserGrantedStorageAccessThroughPrompt(*subFrameStatus.second, topFrameDomain));
#endif
        setUserInteraction(subFrameDomain, true, nowTime(m_timeAdvanceForTesting));
    }

    RunLoop::mainSingleton().dispatch([subFrameDomain = WTF::move(subFrameDomain).isolatedCopy(), topFrameDomain = WTF::move(topFrameDomain).isolatedCopy(), frameID, webPageProxyID, store = Ref { store() }, scope, completionHandler = WTF::move(completionHandler)]() mutable {
        store->callGrantStorageAccessHandler(subFrameDomain, topFrameDomain, frameID, webPageProxyID, scope, [completionHandler = WTF::move(completionHandler), store](StorageAccessWasGranted wasGranted) mutable {
            store->statisticsQueue().dispatch([wasGranted, completionHandler = WTF::move(completionHandler)] () mutable {
                completionHandler(wasGranted);
            });
        });
    });

}

void ResourceLoadStatisticsStore::grandfatherDataForDomains(const HashSet<RegistrableDomain>& domains)
{
    ASSERT(!RunLoop::isMain());

    if (domains.isEmpty())
        return;

    auto transactionScope = beginTransactionIfNecessary();

    for (auto& registrableDomain : domains) {
        auto result = ensureResourceStatisticsForRegistrableDomain(registrableDomain, "grandfatherDataForDomains"_s);
        UNUSED_PARAM(result);
    }

    updateObservedDomainsList("grandfathered = 1"_s, copyToVector(domains), "grandfatherDataForDomains"_s);
}

void ResourceLoadStatisticsStore::updateCookieBlockingWithoutCompletion()
{
    updateCookieBlocking([] { });
}

void ResourceLoadStatisticsStore::logUserInteraction(const TopFrameDomain& domain, CompletionHandler<void()>&& completionHandler)
{
    ASSERT(!RunLoop::isMain());

    auto transactionScope = beginTransactionIfNecessary();

    if (!logUserInteractionRecord(domain))
        return completionHandler();
    updateCookieBlocking(WTF::move(completionHandler));
}

void ResourceLoadStatisticsStore::clearUserInteraction(const RegistrableDomain& domain, CompletionHandler<void()>&& completionHandler)
{
    ASSERT(!RunLoop::isMain());

    auto transactionScope = beginTransactionIfNecessary();

    clearUserInteractionRecords(domain);

    // Update cookie blocking unconditionally since a call to hasHadUserInteraction()
    // to check the previous user interaction status could call clearUserInteraction(),
    // blowing the call stack.
    updateCookieBlocking(WTF::move(completionHandler));
}

String ResourceLoadStatisticsStore::stringFromBuilder(StringBuilder& builder)
{
    return WTF::move(builder).toString();
}

void ResourceLoadStatisticsStore::dumpResourceLoadStatistics(CompletionHandler<void(const String&)>&& completionHandler)
{
    ASSERT_WITH_SECURITY_IMPLICATION(!RunLoop::isMain());
    if (m_dataRecordsBeingRemoved) {
        m_dataRecordRemovalCompletionHandlers.append([weakThis = WeakPtr { *this }, completionHandler = WTF::move(completionHandler)]() mutable {
            RefPtr protectedThis = weakThis;
            if (protectedThis)
                protectedThis->dumpResourceLoadStatistics(WTF::move(completionHandler));
            else
                completionHandler({ });
        });
        return;
    }

    completionHandler(dumpResourceLoadStatisticsText());
}

HashMap<RegistrableDomain, WallTime> ResourceLoadStatisticsStore::allDomainsWithLastAccessedTime() const
{
    ASSERT(!RunLoop::isMain());

    HashMap<RegistrableDomain, WallTime> result;
    for (auto& domainData : domains()) {
        auto lastAccessedTime = std::max(domainData.mostRecentUserInteractionTime, domainData.mostRecentWebPushInteractionTime);
        result.add(WTF::move(domainData.registrableDomain), lastAccessedTime);
    }

    return result;
}

void ResourceLoadStatisticsStore::clear(CompletionHandler<void()>&& completionHandler)
{
    ASSERT(!RunLoop::isMain());

    clearDatabaseContents();

    auto callbackAggregator = CallbackAggregator::create(WTF::move(completionHandler));

    removeAllStorageAccess([callbackAggregator] { });

    auto registrableDomainsToBlockAndDeleteCookiesFor = ensurePrevalentResourcesForDebugMode();
    RegistrableDomainsToBlockCookiesFor domainsToBlock { registrableDomainsToBlockAndDeleteCookiesFor, { }, { }, { } };
    updateCookieBlockingForDomains(WTF::move(domainsToBlock), [callbackAggregator] { });
}

HashMap<TopFrameDomain, Vector<SubResourceDomain>> ResourceLoadStatisticsStore::domainsWithStorageAccess() const
{
    ASSERT(!RunLoop::isMain());

    HashMap<WebCore::RegistrableDomain, Vector<WebCore::RegistrableDomain>> results;
    auto statement = m_database->prepareStatement("SELECT subFrameDomain, registrableDomain FROM (SELECT o.registrableDomain as subFrameDomain, s.topLevelDomainID as topLevelDomainID FROM ObservedDomains as o INNER JOIN StorageAccessUnderTopFrameDomains as s WHERE o.domainID = s.domainID) as z INNER JOIN ObservedDomains ON domainID = z.topLevelDomainID;"_s);
    if (!statement)
        return results;

    while (statement->step() == SQLITE_ROW)
        results.add(RegistrableDomain::uncheckedCreateFromRegistrableDomainString(statement->columnText(1)), Vector<SubResourceDomain> { }).iterator->value.append(RegistrableDomain::uncheckedCreateFromRegistrableDomainString(statement->columnText(0)));

    return results;
}

void ResourceLoadStatisticsStore::updateCookieBlocking(CompletionHandler<void()>&& completionHandler)
{
    ASSERT(!RunLoop::isMain());

    auto domainsToBlockAndDeleteCookiesFor = this->domainsToBlockAndDeleteCookiesFor();
    auto domainsToBlockButKeepCookiesFor = this->domainsToBlockButKeepCookiesFor();
    auto domainsWithUserInteractionAsFirstParty = this->domainsWithUserInteractionAsFirstParty();
    auto domainsWithStorageAccess = this->domainsWithStorageAccess();

    if (domainsToBlockAndDeleteCookiesFor.isEmpty() && domainsToBlockButKeepCookiesFor.isEmpty() && domainsWithUserInteractionAsFirstParty.isEmpty() && domainsWithStorageAccess.isEmpty()) {
        completionHandler();
        return;
    }

    RegistrableDomainsToBlockCookiesFor domainsToBlock { domainsToBlockAndDeleteCookiesFor, domainsToBlockButKeepCookiesFor, domainsWithUserInteractionAsFirstParty, domainsWithStorageAccess };

    if (debugLoggingEnabled() && (!domainsToBlockAndDeleteCookiesFor.isEmpty() || !domainsToBlockButKeepCookiesFor.isEmpty())) {
        debugLogDomainsInBatches("Applying cross-site tracking restrictions"_s, domainsToBlockAndDeleteCookiesFor,
            domainsToBlockButKeepCookiesFor);
    }

    RunLoop::mainSingleton().dispatch([weakThis = WeakPtr { *this }, store = Ref { store() }, domainsToBlock = crossThreadCopy(WTF::move(domainsToBlock)), completionHandler = WTF::move(completionHandler)] () mutable {
        store->callUpdatePrevalentDomainsToBlockCookiesForHandler(domainsToBlock, [weakThis = WTF::move(weakThis), store, completionHandler = WTF::move(completionHandler)]() mutable {
            store->statisticsQueue().dispatch([weakThis = WTF::move(weakThis), completionHandler = WTF::move(completionHandler)]() mutable {
                completionHandler();

                RefPtr protectedThis = weakThis;
                if (!protectedThis)
                    return;

                if (protectedThis->debugLoggingEnabled()) [[unlikely]] {
                    ITP_DEBUG_MODE_RELEASE_LOG("Done applying cross-site tracking restrictions.");
                    protectedThis->debugBroadcastConsoleMessage(MessageSource::ITPDebug, MessageLevel::Info, "[ITP] Done applying cross-site tracking restrictions."_s);
                }
            });
        });
    });
}

} // namespace WebKit

#undef ITP_RELEASE_LOG
#undef ITP_RELEASE_LOG_ERROR
