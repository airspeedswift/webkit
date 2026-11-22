/*
 * Copyright (C) 2019-2023 Apple Inc. All rights reserved.
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

#pragma once

#include "DatabaseUtilities.h"
#include "DidFilterKnownLinkDecoration.h"
#include "ITPThirdPartyData.h"
#include "ResourceLoadStatisticsClassifier.h"
#include "WebResourceLoadStatisticsStore.h"
#include <JavaScriptCore/ConsoleTypes.h>
#include <WebCore/FrameIdentifier.h>
#include <pal/SessionID.h>
#include <wtf/Forward.h>
#include <wtf/RefCountedAndCanMakeWeakPtr.h>
#include <wtf/StdSet.h>
#include <wtf/SwiftBridging.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/WeakPtr.h>

#if HAVE(CORE_PREDICTION)
#include "ResourceLoadStatisticsClassifierCocoa.h"
#endif

namespace WebCore {
class KeyedDecoder;
class KeyedEncoder;
class SQLiteStatement;
enum class StorageAccessPromptWasShown : bool;
enum class StorageAccessWasGranted : uint8_t;
struct ResourceLoadStatistics;
}

namespace WebKit {

// Names for Swift, which cannot spell a class template specialization.
using OptionalDomainID = std::optional<unsigned>;
using RegistrableDomainVector = Vector<WebCore::RegistrableDomain>;
using DomainIDVector = Vector<unsigned>;
using ITPThirdPartyDataVector = Vector<ITPThirdPartyData>;
using ITPThirdPartyDataForSpecificFirstPartyVector = Vector<ITPThirdPartyDataForSpecificFirstParty>;

// Any value is safe to pass: the store checks the slot and its generation on every use, so a stale or made-up handle
// traps or names a live statement of the same store.
struct SQLStatementHandle {
    bool isValid() const { return m_generation; }
    uint32_t m_slot { 0 };
    uint64_t m_generation { 0 };
};

#define FOR_EACH_RESOURCE_LOAD_STATISTICS_CACHED_STATEMENT(macro) \
    macro(ObservedDomainCount, observedDomainCountQuery) \
    macro(InsertObservedDomain, insertObservedDomainQuery) \
    macro(DomainIDFromString, domainIDFromStringQuery) \
    macro(SubframeUnderTopFrameDomainExists, subframeUnderTopFrameDomainExistsQuery) \
    macro(SubresourceUnderTopFrameDomainExists, subresourceUnderTopFrameDomainExistsQuery) \
    macro(SubresourceUniqueRedirectsToExists, subresourceUniqueRedirectsToExistsQuery) \
    macro(MostRecentUserInteraction, mostRecentUserInteractionQuery) \
    macro(UpdateLastSeen, updateLastSeenQuery) \
    macro(UpdateDataRecordsRemoved, updateDataRecordsRemovedQuery) \
    macro(UpdatePrevalentResource, updatePrevalentResourceQuery) \
    macro(IsPrevalentResource, isPrevalentResourceQuery) \
    macro(UpdateVeryPrevalentResource, updateVeryPrevalentResourceQuery) \
    macro(IsVeryPrevalentResource, isVeryPrevalentResourceQuery) \
    macro(ClearPrevalentResource, clearPrevalentResourceQuery) \
    macro(HadUserInteraction, hadUserInteractionQuery) \
    macro(UpdateGrandfathered, updateGrandfatheredQuery) \
    macro(IsScheduledForAllButCookieDataRemoval, isScheduledForAllButCookieDataRemovalQuery) \
    macro(UpdateIsScheduledForAllButCookieDataRemoval, updateIsScheduledForAllButCookieDataRemovalQuery) \
    macro(UpdateMostRecentWebPushInteractionTime, updateMostRecentWebPushInteractionTimeQuery) \
    macro(IsGrandfathered, isGrandfatheredQuery) \
    macro(GetResourceDataByDomainName, getResourceDataByDomainNameQuery) \
    macro(GetAllDomains, getAllDomainsQuery) \
    macro(DomainStringFromDomainID, domainStringFromDomainIDQuery) \
    macro(GetAllSubStatistics, getAllSubStatisticsUnderDomainQuery) \
    macro(StorageAccessExists, storageAccessExistsQuery) \
    macro(GetMostRecentlyUpdatedTimestamp, getMostRecentlyUpdatedTimestampQuery) \
    macro(LinkDecorationExists, linkDecorationExistsQuery) \
    macro(ScriptLoadExists, scriptLoadExistsQuery) \
    macro(SubFrameExists, subFrameExistsQuery) \
    macro(SubResourceExists, subResourceExistsQuery) \
    macro(UniqueRedirectExists, uniqueRedirectExistsQuery) \
    macro(ObservedDomainsExists, observedDomainsExistsQuery) \
    macro(RemoveAllData, removeAllDataQuery) \
    macro(CheckIfTableExists, checkIfTableExistsQuery)

enum class ResourceLoadStatisticsCachedStatement : uint8_t {
#define DECLARE_CACHED_STATEMENT(name, query) name,
    FOR_EACH_RESOURCE_LOAD_STATISTICS_CACHED_STATEMENT(DECLARE_CACHED_STATEMENT)
#undef DECLARE_CACHED_STATEMENT
};

#define COUNT_CACHED_STATEMENT(name, query) + 1
static constexpr size_t resourceLoadStatisticsCachedStatementCount = 0 FOR_EACH_RESOURCE_LOAD_STATISTICS_CACHED_STATEMENT(COUNT_CACHED_STATEMENT);
#undef COUNT_CACHED_STATEMENT

// The names ResourceLoadStatisticsStore.swift logs when a cached statement fails to prepare, passed as an index so that
// opening a statement builds no String.
#define FOR_EACH_RESOURCE_LOAD_STATISTICS_STATEMENT_LOG_LABEL(macro) \
    macro(TableExists, "tableExists"_s) \
    macro(IsEmpty, "isEmpty"_s) \
    macro(DomainID, "domainID"_s) \
    macro(HasStorageAccess, "hasStorageAccess"_s) \
    macro(IsPrevalentResource, "isPrevalentResource"_s) \
    macro(IsVeryPrevalentResource, "isVeryPrevalentResource"_s) \
    macro(IsScheduledForAllButCookieDataRemoval, "isScheduledForAllButCookieDataRemoval"_s) \
    macro(IsRegisteredAsSubresourceUnder, "isRegisteredAsSubresourceUnder"_s) \
    macro(IsRegisteredAsSubFrameUnder, "isRegisteredAsSubFrameUnder"_s) \
    macro(IsRegisteredAsRedirectingTo, "isRegisteredAsRedirectingTo"_s) \
    macro(IsGrandfathered, "isGrandfathered"_s) \
    macro(RemoveDataForDomain, "removeDataForDomain"_s) \
    macro(AllDomains, "allDomains"_s) \
    macro(GetDomainStringFromDomainID, "getDomainStringFromDomainID"_s) \
    macro(DomainIDExistsInDatabase, "domainIDExistsInDatabase"_s) \
    macro(DomainIDExistsInDatabaseLinkDecorationExistsStatement, "domainIDExistsInDatabase linkDecorationExistsStatement"_s) \
    macro(DomainIDExistsInDatabaseSubFrameExistsStatement, "domainIDExistsInDatabase subFrameExistsStatement"_s) \
    macro(DomainIDExistsInDatabaseSubResourceExistsStatement, "domainIDExistsInDatabase subResourceExistsStatement"_s) \
    macro(DomainIDExistsInDatabaseUniqueRedirectExistsStatement, "domainIDExistsInDatabase uniqueRedirectExistsStatement"_s) \
    macro(DomainIDExistsInDatabaseObservedDomainsExistsStatement, "domainIDExistsInDatabase observedDomainsExistsStatement"_s) \
    macro(InsertObservedDomain, "insertObservedDomain"_s) \
    macro(SetUserInteraction, "setUserInteraction"_s) \
    macro(ClearPrevalentResource, "clearPrevalentResource"_s) \
    macro(SetGrandfathered, "setGrandfathered"_s) \
    macro(SetIsScheduledForAllScriptWrittenStorageRemoval, "setIsScheduledForAllScriptWrittenStorageRemoval"_s) \
    macro(SetMostRecentWebPushInteractionTime, "setMostRecentWebPushInteractionTime"_s) \
    macro(EnsureResourceStatisticsForRegistrableDomain, "ensureResourceStatisticsForRegistrableDomain"_s) \
    macro(UpdateLastSeen, "updateLastSeen"_s) \
    macro(UpdateDataRecordsRemoved, "updateDataRecordsRemoved"_s) \
    macro(SetPrevalentResource, "setPrevalentResource"_s) \
    macro(SetPrevalentResourceUpdateVeryPrevalentResource, "setPrevalentResource updateVeryPrevalentResource"_s) \
    macro(PruneStatisticsIfNeeded, "pruneStatisticsIfNeeded"_s) \
    macro(MergeStatistic, "mergeStatistic"_s) \
    macro(HasHadUserInteraction, "hasHadUserInteraction"_s) \
    macro(GetThirdPartyDataForSpecificFirstPartyDomains, "getThirdPartyDataForSpecificFirstPartyDomains"_s) \
    macro(GetMostRecentlyUpdatedTimestamp, "getMostRecentlyUpdatedTimestamp"_s) \
    macro(ResourceToString, "resourceToString"_s) \
    macro(DumpResourceLoadStatistics, "dumpResourceLoadStatistics"_s) \
    macro(InsertExpiredStatisticForTesting, "insertExpiredStatisticForTesting"_s)

enum class ResourceLoadStatisticsStatementLogLabel : uint8_t {
#define DECLARE_STATEMENT_LOG_LABEL(name, text) name,
    FOR_EACH_RESOURCE_LOAD_STATISTICS_STATEMENT_LOG_LABEL(DECLARE_STATEMENT_LOG_LABEL)
#undef DECLARE_STATEMENT_LOG_LABEL
};

#define COUNT_STATEMENT_LOG_LABEL(name, text) + 1
static constexpr size_t resourceLoadStatisticsStatementLogLabelCount = 0 FOR_EACH_RESOURCE_LOAD_STATISTICS_STATEMENT_LOG_LABEL(COUNT_STATEMENT_LOG_LABEL);
#undef COUNT_STATEMENT_LOG_LABEL

// The relationship inserts' query prefixes, which openRelationshipStatement completes with one placeholder per domain,
// passed as an index so that ResourceLoadStatisticsStore.swift builds no SQL of its own.
#define FOR_EACH_RESOURCE_LOAD_STATISTICS_RELATIONSHIP_QUERY(macro) \
    macro(StorageAccessUnderTopFrameDomains, "INSERT OR IGNORE INTO StorageAccessUnderTopFrameDomains (domainID, topLevelDomainID) SELECT ?, domainID FROM ObservedDomains WHERE registrableDomain in ( "_s) \
    macro(TopFrameUniqueRedirectsTo, "INSERT OR IGNORE into TopFrameUniqueRedirectsTo (sourceDomainID, toDomainID) SELECT ?, domainID FROM ObservedDomains where registrableDomain in ( "_s) \
    macro(TopFrameUniqueRedirectsToSinceSameSiteStrictEnforcement, "INSERT OR IGNORE into TopFrameUniqueRedirectsToSinceSameSiteStrictEnforcement (sourceDomainID, toDomainID) SELECT ?, domainID FROM ObservedDomains where registrableDomain in ( "_s) \
    macro(TopFrameUniqueRedirectsFrom, "INSERT OR IGNORE INTO TopFrameUniqueRedirectsFrom (targetDomainID, fromDomainID) SELECT ?, domainID FROM ObservedDomains WHERE registrableDomain in ( "_s) \
    macro(TopFrameLoadedThirdPartyScripts, "INSERT OR IGNORE into TopFrameLoadedThirdPartyScripts (topFrameDomainID, subresourceDomainID) SELECT ?, domainID FROM ObservedDomains where registrableDomain in ( "_s) \
    macro(SubresourceUniqueRedirectsFrom, "INSERT OR IGNORE INTO SubresourceUniqueRedirectsFrom (subresourceDomainID, fromDomainID) SELECT ?, domainID FROM ObservedDomains WHERE registrableDomain in ( "_s) \
    macro(SubframeUnderTopFrameDomains, "INSERT OR REPLACE into SubframeUnderTopFrameDomains (subFrameDomainID, lastUpdated, topFrameDomainID) SELECT ?, ?, domainID FROM ObservedDomains where registrableDomain in ( "_s) \
    macro(TopFrameLinkDecorationsFrom, "INSERT OR REPLACE INTO TopFrameLinkDecorationsFrom (toDomainID, lastUpdated, fromDomainID) SELECT ?, ?, domainID FROM ObservedDomains WHERE registrableDomain in ( "_s) \
    macro(SubresourceUnderTopFrameDomains, "INSERT OR REPLACE INTO SubresourceUnderTopFrameDomains (subresourceDomainID, lastUpdated, topFrameDomainID) SELECT ?, ?, domainID FROM ObservedDomains WHERE registrableDomain in ( "_s) \
    macro(SubresourceUniqueRedirectsTo, "INSERT OR REPLACE INTO SubresourceUniqueRedirectsTo (subresourceDomainID, lastUpdated, toDomainID) SELECT ?, ?, domainID FROM ObservedDomains WHERE registrableDomain in ( "_s)

enum class ResourceLoadStatisticsRelationshipQuery : uint8_t {
#define DECLARE_RELATIONSHIP_QUERY(name, query) name,
    FOR_EACH_RESOURCE_LOAD_STATISTICS_RELATIONSHIP_QUERY(DECLARE_RELATIONSHIP_QUERY)
#undef DECLARE_RELATIONSHIP_QUERY
};

#define COUNT_RELATIONSHIP_QUERY(name, query) + 1
static constexpr size_t resourceLoadStatisticsRelationshipQueryCount = 0 FOR_EACH_RESOURCE_LOAD_STATISTICS_RELATIONSHIP_QUERY(COUNT_RELATIONSHIP_QUERY);
#undef COUNT_RELATIONSHIP_QUERY

class OperatingDate {
public:
    OperatingDate() = default;
    
    static OperatingDate fromWallTime(WallTime);
    static OperatingDate today(Seconds timeAdvanceForTesting);
    Seconds secondsSinceEpoch() const;
    int year() const { return m_year; }
    int month() const { return m_month; }
    int monthDay() const { return m_monthDay; }

    friend bool operator==(const OperatingDate&, const OperatingDate&) = default;
    friend auto operator<=>(const OperatingDate& a, const OperatingDate& b) { return a.secondsSinceEpoch() <=> b.secondsSinceEpoch(); }
    
    OperatingDate(int year, int month, int monthDay)
        : m_year(year)
        , m_month(month)
        , m_monthDay(monthDay)
    { }

private:
    int m_year { 0 };
    int m_month { 0 }; // [0, 11].
    int m_monthDay { 0 }; // [1, 31].
};

enum class OperatingDatesWindow : uint8_t { Long, Short, ForLiveOnTesting, ForReproTesting };
enum class CookieAccess : uint8_t { CannotRequest, BasedOnCookiePolicy, OnlyIfGranted };
enum class CanRequestStorageAccessWithoutUserInteraction : bool { No, Yes };
enum class DataRemovalFrequency : uint8_t { Never, Short, Long };

// This is always constructed / used / destroyed on the WebResourceLoadStatisticsStore's statistics queue.
class SWIFT_PRIVATE_FILEID("WebKit/ResourceLoadStatisticsStore.swift") ResourceLoadStatisticsStore final : public RefCountedAndCanMakeWeakPtr<ResourceLoadStatisticsStore>,  public DatabaseUtilities {
    WTF_MAKE_TZONE_ALLOCATED(ResourceLoadStatisticsStore);
public:
    using ResourceLoadStatistics = WebCore::ResourceLoadStatistics;
    using RegistrableDomain = WebCore::RegistrableDomain;
    using TopFrameDomain = WebCore::RegistrableDomain;
    using SubFrameDomain = WebCore::RegistrableDomain;
    using SubResourceDomain = WebCore::RegistrableDomain;
    using RedirectDomain = WebCore::RegistrableDomain;
    using RedirectedFromDomain = WebCore::RegistrableDomain;
    using RedirectedToDomain = WebCore::RegistrableDomain;
    using NavigatedFromDomain = WebCore::RegistrableDomain;
    using NavigatedToDomain = WebCore::RegistrableDomain;
    using DomainInNeedOfStorageAccess = WebCore::RegistrableDomain;
    using OpenerDomain = WebCore::RegistrableDomain;
    
    static Ref<ResourceLoadStatisticsStore> create(WebResourceLoadStatisticsStore& webResourceLoadStatisticsStore, SuspendableWorkQueue& suspendableWorkQueue, ShouldIncludeLocalhost shouldIncludeLocalhost, const String& storageDirectoryPath, PAL::SessionID sessionID)
    {
        return adoptRef(*new ResourceLoadStatisticsStore(webResourceLoadStatisticsStore, suspendableWorkQueue, shouldIncludeLocalhost, storageDirectoryPath, sessionID));
    }

    ~ResourceLoadStatisticsStore();

    void clear(CompletionHandler<void()>&&);
    bool isEmpty() const;
    ITPThirdPartyDataVector aggregatedThirdPartyData() const;
    void updateCookieBlocking(CompletionHandler<void()>&&);
    void processStatisticsAndDataRecords(CompletionHandler<void()>&&);
    NODELETE void cancelPendingStatisticsProcessingRequest();
    void mergeStatistics(Vector<ResourceLoadStatistics>&&);
    void runIncrementalVacuumCommand();
    void dumpResourceLoadStatistics(CompletionHandler<void(const String&)>&&);
    bool isNewResourceLoadStatisticsDatabaseFile() const { return m_isNewResourceLoadStatisticsDatabaseFile; }
    void setIsNewResourceLoadStatisticsDatabaseFile(bool isNewResourceLoadStatisticsDatabaseFile) { m_isNewResourceLoadStatisticsDatabaseFile = isNewResourceLoadStatisticsDatabaseFile; }

    void requestStorageAccessUnderOpener(DomainInNeedOfStorageAccess&&, WebPageProxyIdentifier openerWebPageProxyID, OpenerDomain&&, CanRequestStorageAccessWithoutUserInteraction);
    void removeAllStorageAccess(CompletionHandler<void()>&&);

    std::optional<HashMap<RegistrableDomain, WallTime>> loadWebsitesWithUserInteraction();

    void grandfatherExistingWebsiteData(CompletionHandler<void()>&&);
    void setGrandfathered(RegistrableDomain, bool value);
    bool isGrandfathered(RegistrableDomain) const;
    NODELETE void setGrandfatheringTime(Seconds);

    bool isRegisteredAsSubresourceUnder(SubResourceDomain, TopFrameDomain) const;
    bool isRegisteredAsSubFrameUnder(SubFrameDomain, TopFrameDomain) const;
    bool isRegisteredAsRedirectingTo(RedirectedFromDomain, RedirectedToDomain) const;

    void clearPrevalentResource(RegistrableDomain);
    bool isPrevalentResource(RegistrableDomain) const;
    bool isVeryPrevalentResource(RegistrableDomain) const;
    void setPrevalentResource(RegistrableDomain);
    void setVeryPrevalentResource(RegistrableDomain);
    void setMostRecentWebPushInteractionTime(RegistrableDomain);

    void setSubframeUnderTopFrameDomain(SubFrameDomain, TopFrameDomain);
    void setSubresourceUnderTopFrameDomain(SubResourceDomain, TopFrameDomain);
    void setSubresourceUniqueRedirectTo(SubResourceDomain, RedirectDomain);
    void setSubresourceUniqueRedirectFrom(SubResourceDomain, RedirectDomain);
    void setTopFrameUniqueRedirectTo(TopFrameDomain, RedirectDomain);
    void setTopFrameUniqueRedirectFrom(TopFrameDomain, RedirectDomain);

    NODELETE void setIsRunningTest(bool);
    void logTestingEvent(String&&);
    void setTimeAdvanceForTesting(Seconds);

    NODELETE void setMaxStatisticsEntries(size_t maximumEntryCount);
    NODELETE void setPruneEntriesDownTo(size_t pruneTargetCount);
    void resetParametersToDefaultValues();

    bool shouldSkip(RegistrableDomain) const;
    NODELETE void setShouldClassifyResourcesBeforeDataRecordsRemoval(bool);
    NODELETE void setTimeToLiveUserInteraction(Seconds);
    NODELETE void setMinimumTimeBetweenDataRecordsRemoval(Seconds);
    void setResourceLoadStatisticsDebugMode(bool);
    bool isDebugModeEnabled() const { return m_debugModeEnabled; };
    void setPrevalentResourceForDebugMode(RegistrableDomain);
    void setThirdPartyCookieBlockingMode(WebCore::ThirdPartyCookieBlockingMode mode) { m_thirdPartyCookieBlockingMode = mode; };
    WebCore::ThirdPartyCookieBlockingMode thirdPartyCookieBlockingMode() const { return m_thirdPartyCookieBlockingMode; };
    void setSameSiteStrictEnforcementEnabled(WebCore::SameSiteStrictEnforcementEnabled enabled) { m_sameSiteStrictEnforcementEnabled = enabled; };
    bool isSameSiteStrictEnforcementEnabled() const { return m_sameSiteStrictEnforcementEnabled == WebCore::SameSiteStrictEnforcementEnabled::Yes; };
    void setFirstPartyWebsiteDataRemovalMode(WebCore::FirstPartyWebsiteDataRemovalMode mode) { m_firstPartyWebsiteDataRemovalMode = mode; }
    WebCore::FirstPartyWebsiteDataRemovalMode firstPartyWebsiteDataRemovalMode() const { return m_firstPartyWebsiteDataRemovalMode; }
    void setPersistedDomains(HashSet<RegistrableDomain>&& domains) { m_persistedDomains = WTF::move(domains); }
    void setStandaloneApplicationDomain(RegistrableDomain&& domain) { m_standaloneApplicationDomain = WTF::move(domain); }
#if ENABLE(APP_BOUND_DOMAINS)
    void setAppBoundDomains(HashSet<RegistrableDomain>&&);
#endif
#if ENABLE(MANAGED_DOMAINS)
    void setManagedDomains(HashSet<RegistrableDomain>&&);
#endif

    void hasStorageAccess(SubFrameDomain&&, TopFrameDomain&&, std::optional<WebCore::FrameIdentifier>, WebPageProxyIdentifier, CanRequestStorageAccessWithoutUserInteraction, CompletionHandler<void(bool)>&&);
    void requestStorageAccess(SubFrameDomain&&, TopFrameDomain&&, WebCore::FrameIdentifier, WebPageProxyIdentifier, WebCore::StorageAccessScope, CanRequestStorageAccessWithoutUserInteraction, CompletionHandler<void(StorageAccessStatus)>&&);
    void queryStorageAccessPermission(const SubFrameDomain&, const TopFrameDomain&, CompletionHandler<void(WebCore::PermissionState)>&&);
    enum class AddedRecord : bool { No, Yes };
    using AddedRecordAndDomainID = std::pair<AddedRecord, std::optional<unsigned>>;
    AddedRecordAndDomainID grantStorageAccessPermission(RegistrableDomain topFrameDomain, RegistrableDomain subFrameDomain);
    void revokeStorageAccessPermission(RegistrableDomain);
    void grantStorageAccess(SubFrameDomain&&, TopFrameDomain&&, WebCore::FrameIdentifier, WebPageProxyIdentifier, WebCore::StorageAccessPromptWasShown, WebCore::StorageAccessScope, CompletionHandler<void(WebCore::StorageAccessWasGranted)>&&);

    void logFrameNavigation(NavigatedToDomain, TopFrameDomain, NavigatedFromDomain, bool isRedirect, bool isMainFrame, Seconds delayAfterMainFrameDocumentLoad, bool wasPotentiallyInitiatedByUser);
    void logCrossSiteLoadWithLinkDecoration(NavigatedFromDomain, NavigatedToDomain, DidFilterKnownLinkDecoration);

    void logUserInteraction(const TopFrameDomain&, CompletionHandler<void()>&&);
    void clearUserInteraction(const RegistrableDomain&, CompletionHandler<void()>&&);
    bool hasHadUserInteraction(RegistrableDomain, OperatingDatesWindow);

    void setLastSeen(RegistrableDomain primaryDomain, Seconds);
    bool isCorrectSubStatisticsCount(RegistrableDomain, TopFrameDomain);

    void removeDataForDomain(RegistrableDomain);

    RegistrableDomainVector allDomains() const;
    HashMap<RegistrableDomain, WallTime> allDomainsWithLastAccessedTime() const;
    HashSet<RegistrableDomain> domainsExemptFromWebsiteDataDeletion() const;

    void didCreateNetworkProcess();

    const WebResourceLoadStatisticsStore& store() const { return m_store.get(); }

    bool domainIDExistsInDatabase(int);
    bool observedDomainNavigationWithLinkDecoration(int);
    std::optional<Vector<String>> checkForMissingTablesInSchema();

    void includeTodayAsOperatingDateIfNecessary();
    void insertExpiredStatisticForTesting(RegistrableDomain, unsigned numberOfOperatingDaysPassed, bool hasUserInteraction,
        bool isScheduledForAllButCookieDataRemoval, bool);
    static void interruptAllDatabases();

    // Public: when DomainData is private, the Swift compiler crashes while serializing the module (in SerializeSILPass).
    struct DomainData {
        unsigned domainID;
        RegistrableDomain registrableDomain;
        WallTime mostRecentUserInteractionTime;
        WallTime mostRecentWebPushInteractionTime;
        bool hadUserInteraction;
        bool grandfathered;
        DataRemovalFrequency dataRemovalFrequency;
        unsigned topFrameUniqueRedirectsToSinceSameSiteStrictEnforcement;
    };
    using DomainDataVector = Vector<DomainData>;
    DomainDataVector domains() const;

private:
    ResourceLoadStatisticsStore(WebResourceLoadStatisticsStore&, SuspendableWorkQueue&, ShouldIncludeLocalhost, const String& storageDirectoryPath, PAL::SessionID);

    WebResourceLoadStatisticsStore& store() { return m_store.get(); }

    struct Parameters {
        size_t pruneEntriesDownTo { 800 };
        size_t maxStatisticsEntries { 1000 };
        std::optional<Seconds> timeToLiveUserInteraction;
        Seconds minimumTimeBetweenDataRecordsRemoval { 1_h };
        Seconds grandfatheringTime { 24_h * 7 };
        Seconds cacheMaxAgeCapTime { 24_h * 7 };
        Seconds clientSideCookiesAgeCapTime { 24_h * 7 };
        Seconds clientSideCookiesForLinkDecorationTargetPageAgeCapTime { 24_h };
        Seconds minDelayAfterMainFrameDocumentLoadToNotBeARedirect { 5_s };
        size_t minimumTopFrameRedirectsForSameSiteStrictEnforcement { 10 };
        bool shouldClassifyResourcesBeforeDataRecordsRemoval { true };
        bool isRunningTest { false };
    };
    // For Swift, which imports a returned reference as a pointer.
    static String string(const RegistrableDomain& domain) { return domain.string(); }
    static String emptyString() { return WTF::emptyString(); }
    // For Swift, which does not accept a call named unchecked*.
    static RegistrableDomain registrableDomainFromHost(const String& host) { return RegistrableDomain::uncheckedCreateFromHost(host); }
    // For Swift, which sees StringBuilder::toString()'s reference result as a pointer: the builder's text, moved out.
    static String stringFromBuilder(StringBuilder&);
    static Seconds reduceTimeResolution(Seconds t) { return ResourceLoadStatistics::reduceTimeResolution(WallTime { } + t) - WallTime { }; }
    void clearEndOfGrandfatheringTimeStamp() { m_endOfGrandfatheringTimestamp = { }; }
    void debugBroadcastConsoleMessage(MessageSource, MessageLevel, const String& message);
    void debugLogDomainsInBatches(String action, RegistrableDomainVector, RegistrableDomainVector);
    bool debugLoggingEnabled() const { return m_debugLoggingEnabled; }
    bool debugModeEnabled() const { return m_debugModeEnabled; }
    bool shouldExemptFromWebsiteDataDeletion(const RegistrableDomain&) const;

    String getDomainStringFromDomainID(unsigned) const final;
    String dumpResourceLoadStatisticsText() const;
    void mergeStatistic(RegistrableDomain, WallTime lastSeen, bool hadUserInteraction, WallTime mostRecentUserInteractionTime, bool grandfathered, bool isPrevalentResource, bool isVeryPrevalentResource, unsigned dataRecordsRemoved, bool gotLinkDecorationFromPrevalentResource);
    void incrementRecordsDeletedCountForDomains(HashSet<RegistrableDomain>&&);
    [[nodiscard]] bool insertObservedDomainRecord(RegistrableDomain, double lastSeen, bool hadUserInteraction, double mostRecentUserInteractionTime, bool grandfathered, bool isPrevalent, bool isVeryPrevalent, unsigned dataRecordsRemoved, unsigned timesAccessedAsFirstPartyDueToUserInteraction, unsigned timesAccessedAsFirstPartyDueToStorageAccessAPI, bool gotLinkDecorationFromPrevalentResource);
    void insertDomainRelationshipsRecord(RegistrableDomain, RegistrableDomainVector storageAccessUnderTopFrameDomains,
        RegistrableDomainVector topFrameUniqueRedirectsTo, RegistrableDomainVector topFrameUniqueRedirectsToSinceSameSiteStrictEnforcement,
        RegistrableDomainVector topFrameUniqueRedirectsFrom, RegistrableDomainVector subframeUnderTopFrameDomains,
        RegistrableDomainVector subresourceUnderTopFrameDomains, RegistrableDomainVector subresourceUniqueRedirectsTo,
        RegistrableDomainVector subresourceUniqueRedirectsFrom, RegistrableDomainVector topFrameLinkDecorationsFrom,
        RegistrableDomainVector topFrameLoadedThirdPartyScripts);
    OptionalDomainID domainID(RegistrableDomain) const;
    bool domainExists(const RegistrableDomain&) const;
    void setUserInteraction(RegistrableDomain, bool hadUserInteraction, WallTime);
    bool logUserInteractionRecord(TopFrameDomain);
    void clearUserInteractionRecords(RegistrableDomain);
    void updateCookieBlockingWithoutCompletion();
    Vector<RegistrableDomain> domainsToBlockAndDeleteCookiesFor() const;
    Vector<RegistrableDomain> domainsToBlockButKeepCookiesFor() const;
    Vector<RegistrableDomain> domainsWithUserInteractionAsFirstParty() const;
    HashMap<TopFrameDomain, Vector<SubResourceDomain>> domainsWithStorageAccess() const;
    void updateObservedDomainsList(String updateClause, RegistrableDomainVector, String logContext);

    bool hasUserGrantedStorageAccessThroughPrompt(unsigned domainID, RegistrableDomain);

    // For Swift, which cannot spell a HashMap: the indexes of keys in the order a HashMap<unsigned, T> filled from them visits them.
    static DomainIDVector hashMapIterationOrder(DomainIDVector keys);

    CookieAccess cookieAccess(SubResourceDomain, TopFrameDomain, CanRequestStorageAccessWithoutUserInteraction);
    void updateCookieBlockingForDomains(RegistrableDomainsToBlockCookiesFor&&, CompletionHandler<void()>&&);

    void classifyPrevalentResources();
    void grantStorageAccessInternal(SubFrameDomain&&, TopFrameDomain&&, std::optional<WebCore::FrameIdentifier>, WebPageProxyIdentifier, WebCore::StorageAccessPromptWasShown, WebCore::StorageAccessScope, CanRequestStorageAccessWithoutUserInteraction, CompletionHandler<void(WebCore::StorageAccessWasGranted)>&&);
    
    // reason is used for logging purpose.
    [[nodiscard]] AddedRecordAndDomainID ensureResourceStatisticsForRegistrableDomain(RegistrableDomain, String reason);
    RegistrableDomainsToDeleteOrRestrictWebsiteDataFor registrableDomainsToDeleteOrRestrictWebsiteDataFor();

    bool shouldRemoveDataRecords() const;
    void setDebugLogggingEnabled(bool enabled) { m_debugLoggingEnabled  = enabled; }
    Vector<RegistrableDomain> ensurePrevalentResourcesForDebugMode();
    void setDataRecordsBeingRemoved(bool);
    void removeDataRecords(CompletionHandler<void()>&&);
    void setCacheMaxAgeCap(Seconds);
    void updateCacheMaxAgeCap();
    void updateClientSideCookiesAgeCap();
    const MemoryCompactLookupOnlyRobinHoodHashMap<String, TableAndIndexPair>& expectedTableAndIndexQueries() final;
    std::span<const ASCIILiteral> sortedTables() final;
    void grandfatherDataForDomains(const HashSet<RegistrableDomain>&);
    void scheduleStatisticsProcessingRequestIfNecessary();
    void pruneStatisticsIfNeeded();

    void openITPDatabase();
    void clearDatabaseContents();
    bool createUniqueIndices() final;
    bool createSchema() final;
    void addMissingTablesIfNecessary();
    bool missingUniqueIndices();
    bool needsUpdatedSchema() final;
    bool missingReferenceToObservedDomains();
    void migrateDataToPCMDatabaseIfNecessary();
    void openAndUpdateSchemaIfNecessary();
    bool tableExists(String);
    void deleteTable(StringView);
    void destroyStatements() final;

    // commitTransactionForSwift(true) commits what beginTransactionIfNecessaryForSwift() started.
    bool beginTransactionIfNecessaryForSwift();
    void commitTransactionForSwift(bool didBeginTransaction);

    // The columns of ObservedDomains, in the order of its CREATE TABLE and insertObservedDomainQuery.
    enum class ObservedDomainsColumn : int {
        RegistrableDomain = 1,
        LastSeen = 2,
        HadUserInteraction = 3,
        MostRecentUserInteractionTime = 4,
        Grandfathered = 5,
        IsPrevalent = 6,
        IsVeryPrevalent = 7,
        DataRecordsRemoved = 8,
        TimesAccessedAsFirstPartyDueToUserInteraction = 9,
        TimesAccessedAsFirstPartyDueToStorageAccessAPI = 10,
        IsScheduledForAllButCookieDataRemoval = 11,
        MostRecentWebPushInteractionTime = 12,
    };
    // For missingUniqueIndices(): createUniqueIndices()'s 12 commands, plus the index SQLite makes for ObservedDomains.
    static constexpr int expectedIndexCount() { return 13; }

    // The SQLite access of ResourceLoadStatisticsStore.swift, through handles that the .cpp checks on every use.
    SQLStatementHandle openCachedStatement(ResourceLoadStatisticsCachedStatement, ResourceLoadStatisticsStatementLogLabel) const;
    SQLStatementHandle openStatement(String query) const;
    SQLStatementHandle openRelationshipStatement(ResourceLoadStatisticsRelationshipQuery, uint32_t domainCount) const;
    void closeStatement(SQLStatementHandle) const;
    int bindInt(SQLStatementHandle, int index, int value) const;
    int bindText(SQLStatementHandle, int index, String value) const;
    int bindDouble(SQLStatementHandle, int index, double value) const;
    int step(SQLStatementHandle) const;
    int reset(SQLStatementHandle) const;
    int columnInt(SQLStatementHandle, int column) const;
    String columnText(SQLStatementHandle, int column) const;
    double columnDouble(SQLStatementHandle, int column) const;
    int databaseLastError() const { return m_database->lastError(); }
    String databaseLastErrorMsg() const { return String::fromLatin1(m_database->lastErrorMsg()); }
    int databaseRunIncrementalVacuumCommand() const { return m_database->runIncrementalVacuumCommand(); }
    void databaseClearAllTables() const { m_database->clearAllTables(); }

    CheckedRef<WebResourceLoadStatisticsStore> m_store;
    const Ref<SuspendableWorkQueue> m_workQueue;
#if HAVE(CORE_PREDICTION)
    ResourceLoadStatisticsClassifierCocoa m_resourceLoadStatisticsClassifier;
#else
    ResourceLoadStatisticsClassifier m_resourceLoadStatisticsClassifier;
#endif
    Parameters m_parameters;
    WallTime m_endOfGrandfatheringTimestamp;
    RegistrableDomain m_debugManualPrevalentResource;
    MonotonicTime m_lastTimeDataRecordsWereRemoved;
    uint64_t m_lastStatisticsProcessingRequestIdentifier { 0 };
    std::optional<uint64_t> m_pendingStatisticsProcessingRequestIdentifier;
    const RegistrableDomain m_debugStaticPrevalentResource { URL { "https://3rdpartytestwebkit.org"_str } };
    RegistrableDomain m_standaloneApplicationDomain;
    HashSet<RegistrableDomain> m_appBoundDomains;
    HashSet<RegistrableDomain> m_managedDomains;
    HashSet<RegistrableDomain> m_persistedDomains;
    struct __attribute__((availability(swift, unavailable))) StatementSlot {
        std::unique_ptr<WebCore::SQLiteStatement> statement;
        uint64_t generation { 1 };
    };
    mutable Vector<StatementSlot> m_statements __attribute__((availability(swift, unavailable))) { Vector<StatementSlot>(resourceLoadStatisticsCachedStatementCount) };

    Vector<CompletionHandler<void()>> m_dataRecordRemovalCompletionHandlers;
    Seconds m_timeAdvanceForTesting;

    PAL::SessionID m_sessionID;
    unsigned m_operatingDatesSize { 0 };
    std::optional<OperatingDate> m_longWindowOperatingDate;
    std::optional<OperatingDate> m_shortWindowOperatingDate;
    OperatingDate m_mostRecentOperatingDate;
    WebCore::ThirdPartyCookieBlockingMode m_thirdPartyCookieBlockingMode { WebCore::ThirdPartyCookieBlockingMode::All };
    WebCore::SameSiteStrictEnforcementEnabled m_sameSiteStrictEnforcementEnabled { WebCore::SameSiteStrictEnforcementEnabled::No };
    WebCore::FirstPartyWebsiteDataRemovalMode m_firstPartyWebsiteDataRemovalMode { WebCore::FirstPartyWebsiteDataRemovalMode::AllButCookies };
    ShouldIncludeLocalhost m_shouldIncludeLocalhost { ShouldIncludeLocalhost::Yes };
    bool m_debugLoggingEnabled { false };
    bool m_debugModeEnabled { false };
    bool m_dataRecordsBeingRemoved { false };
    bool m_isNewResourceLoadStatisticsDatabaseFile { false };
};

} // namespace WebKit
