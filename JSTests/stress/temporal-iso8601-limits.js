//@ requireOptions("--useTemporal=1")

function shouldBe(actual, expected, msg) {
    if (actual !== expected)
        throw new Error(`${msg}: expected ${expected} but got ${actual}`);
}

function shouldThrow(fn, errorType, message, msg) {
    let thrown = null;
    try { fn(); } catch (e) { thrown = e; }
    if (!thrown)
        throw new Error(`${msg}: expected ${errorType.name} but nothing was thrown`);
    if (!(thrown instanceof errorType))
        throw new Error(`${msg}: expected ${errorType.name} but got ${thrown}`);
    if (message !== undefined && thrown.message !== message)
        throw new Error(`${msg}: expected message "${message}" but got "${thrown.message}"`);
}

const invalidDuration = "Temporal.Duration properties must be finite and of consistent sign";

// The longest strings the formatters produce: extreme years with six digits and a sign, nine fraction digits,
// an offset, a long time zone name and a critical calendar annotation with a long calendar identifier.
{
    const cal = "islamic-umalqura";
    const critical = { calendarName: "critical" };
    shouldBe(new Temporal.PlainYearMonth(-271821, 4, cal, 19).toString(critical), "-271821-04-19[!u-ca=islamic-umalqura]", "PlainYearMonth");
    shouldBe(Temporal.PlainYearMonth.from({ year: -271821, month: 4 }).toString(critical), "-271821-04-01[!u-ca=iso8601]", "PlainYearMonth iso8601");
    shouldBe(Temporal.PlainMonthDay.from({ monthCode: "M12", day: 30, calendar: cal }).toString(critical), "1971-02-26[!u-ca=islamic-umalqura]", "PlainMonthDay");
    shouldBe(new Temporal.PlainDate(-271821, 4, 19, cal).toString(critical), "-271821-04-19[!u-ca=islamic-umalqura]", "PlainDate");
    shouldBe(new Temporal.PlainDateTime(-271821, 4, 19, 0, 0, 0, 0, 0, 1, cal).toString(critical),
        "-271821-04-19T00:00:00.000000001[!u-ca=islamic-umalqura]", "PlainDateTime min");
    shouldBe(new Temporal.PlainDateTime(275760, 9, 13, 0, 0, 0, 0, 0, 0, cal).toString({ calendarName: "critical", fractionalSecondDigits: 9 }),
        "+275760-09-13T00:00:00.000000000[!u-ca=islamic-umalqura]", "PlainDateTime max");
    const zonedOptions = { calendarName: "critical", timeZoneName: "critical", fractionalSecondDigits: 9 };
    shouldBe(new Temporal.ZonedDateTime(0n, "America/Argentina/ComodRivadavia", cal).toString(zonedOptions),
        "1969-12-31T21:00:00.000000000-03:00[!America/Argentina/ComodRivadavia][!u-ca=islamic-umalqura]", "ZonedDateTime named zone");
    shouldBe(new Temporal.ZonedDateTime(8640000000000000000000n, "+23:59", cal).toString(zonedOptions),
        "+275760-09-13T23:59:00.000000000+23:59[!+23:59][!u-ca=islamic-umalqura]", "ZonedDateTime max");
    shouldBe(new Temporal.ZonedDateTime(-8639999999999999999999n, "-23:59", cal).toString({ calendarName: "critical", timeZoneName: "critical" }),
        "-271821-04-19T00:01:00.000000001-23:59[!-23:59][!u-ca=islamic-umalqura]", "ZonedDateTime min");
    shouldBe(new Temporal.Instant(-8640000000000000000000n).toString({ timeZone: "-23:59", fractionalSecondDigits: 9 }),
        "-271821-04-19T00:01:00.000000000-23:59", "Instant min");
    shouldBe(new Temporal.Instant(8640000000000000000000n - 1n).toString({ timeZone: "+23:59", fractionalSecondDigits: 9 }),
        "+275760-09-13T23:58:59.999999999+23:59", "Instant max");
}

// Duration integers: up to 9 digits, from 10 digits to 2^53 and past it, and long runs of leading zeros
// (19, 20, 38, 39 digits and more).
{
    const valid = [
        ["P123456789D", "P123456789D"],
        ["P1234567890D", "P1234567890D"],
        ["P999999999W", "P999999999W"],
        ["P000000000D", "PT0S"],
        ["P4294967295Y", "P4294967295Y"],
        ["PT9007199254740991S", "PT9007199254740991S"],
        ["PT9007199254740991.999999999S", "PT9007199254740991.999999999S"],
        ["PT9007199254740990.5S", "PT9007199254740990.5S"],
        ["PT150119987579016M", "PT150119987579016M"],
        ["PT2501999792983H", "PT2501999792983H"],
        ["P104249991374D", "P104249991374D"],
        ["PT" + "0".repeat(4) + "9007199254740991S", "PT9007199254740991S"],
        ["PT" + "0".repeat(23) + "9007199254740991S", "PT9007199254740991S"],
    ];
    for (const n of [8, 9, 10, 18, 19, 20, 37, 38, 39, 40, 60])
        valid.push(["PT" + "0".repeat(n - 1) + "1S", "PT1S"]);
    for (const [input, expected] of valid)
        shouldBe(Temporal.Duration.from(input).toString(), expected, input);

    const outOfRange = [
        "PT9007199254740992S",
        "PT9007199254740993S",
        "PT1234567890123456789S",
        "PT12345678901234567890S",
        "PT12345678901234567890123456789012345678S",
        "PT123456789012345678901234567890123456789S",
        "P4294967296Y",
        "PT150119987579017M",
        "PT2501999792984H",
        "P104249991375D",
    ];
    for (const input of outOfRange)
        shouldThrow(() => Temporal.Duration.from(input), RangeError, invalidDuration, input);
}

// Duration fractions: one to nine digits on the last unit, carried into the smaller units.
{
    const cases = [
        ["PT1.1H", "PT1H6M"],
        ["PT1.123456789H", "PT1H7M24.4444404S"],
        ["-PT1.123456789H", "-PT1H7M24.4444404S"],
        ["PT0.000000001M", "PT0.00000006S"],
        ["PT1.5M", "PT1M30S"],
        ["P1DT0.5H", "P1DT30M"],
        ["PT999999999.999999999S", "PT999999999.999999999S"],
    ];
    for (const [input, expected] of cases)
        shouldBe(Temporal.Duration.from(input).toString(), expected, input);
    shouldThrow(() => Temporal.Duration.from("PT1.1234567891H"), RangeError, "'PT1.1234567891H' is not a valid Duration string", "ten fraction digits");
}

// Days 28 to 31 at the end of each kind of month, and the representable range's first and last days.
{
    for (const input of ["2021-02-28", "2020-02-29", "2000-02-29", "2021-04-30", "2021-01-31", "2021-12-31", "+275760-09-13", "-271821-04-19"])
        shouldBe(Temporal.PlainDate.from(input).toString(), input, input);
    for (const input of ["2021-02-29", "2020-02-30", "1900-02-29", "2100-02-29", "2021-04-31", "2021-01-32", "2021-06-00"])
        shouldThrow(() => Temporal.PlainDate.from(input), RangeError, "invalid date string", input);
    for (const input of ["+275760-09-14", "-271821-04-18"])
        shouldThrow(() => Temporal.PlainDate.from(input), RangeError, "date time is out of range of ECMAScript representation", input);
}

// Time fractions of one to nine digits, either separator, and a leap second.
{
    const digits = "123456789";
    for (let n = 1; n <= 9; ++n) {
        const input = "12:34:56." + digits.slice(0, n);
        shouldBe(Temporal.PlainTime.from(input).toString(), input, input);
    }
    shouldBe(Temporal.PlainTime.from("12:34:56,000000001").toString(), "12:34:56.000000001", "comma");
    shouldBe(Temporal.PlainTime.from("23:59:60.999999999").toString(), "23:59:59.999999999", "leap second");
    shouldBe(Temporal.PlainTime.from("123456.987654321").toString(), "12:34:56.987654321", "basic format");
    for (const input of ["12:34:56.1234567890", "12:34:56."])
        shouldThrow(() => Temporal.PlainTime.from(input), RangeError, "invalid time string", input);
    shouldBe(Temporal.Instant.from("2020-01-01T00:00+23:59:59.999999999[+23:59]").toString(), "2019-12-31T00:00:00.000000001Z", "offset with nine fraction digits");
    shouldBe(Temporal.Instant.from("2020-01-01T00:00:00.123456789+01:00").toString(), "2019-12-31T23:00:00.123456789Z", "instant fraction");
}
