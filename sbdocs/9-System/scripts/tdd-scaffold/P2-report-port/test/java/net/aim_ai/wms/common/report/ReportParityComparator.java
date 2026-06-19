package net.aim_ai.wms.common.report;

import static org.assertj.core.api.Assertions.assertThat;

import java.math.BigDecimal;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.List;
import java.util.function.Function;

/**
 * TDD-GATE TEST UTIL — encodes the Phase A parity-comparator contract from plan
 * 260420-v2-port-plpgsql-functions-to-java.md §5 / §6. This is the load-bearing proof that the
 * {@code ''}-un-doubling, {@code $N -> :namedParam} mapping, and {@code UNION} (dedup) semantics
 * were preserved when the PL/pgSQL bodies were ported to Java (plan §2.3).
 *
 * <p>"Java output == DB-function output" is underspecified, so this comparator pins all four
 * sub-criteria the plan requires:</p>
 *
 * <ol>
 *   <li><b>(a) BigDecimal comparison is scale-INSENSITIVE.</b> PostgreSQL {@code numeric} and H2
 *       may differ in trailing-zero scale and {@code BigDecimal.equals()} is scale-sensitive
 *       ({@code 1.0 != 1.00}). Numeric columns are compared with {@code compareTo(...) == 0}, NEVER
 *       {@code .equals()}.</li>
 *   <li><b>(b) Rows compared IN ORDER under a deterministic TOTAL {@code ORDER BY}.</b> Both the
 *       Java path and the DB-function query MUST end in an {@code ORDER BY} over a column set that
 *       uniquely orders the rows. This comparator compares row {@code i} to row {@code i} with no
 *       re-sorting; it asserts equal row counts first. <b>ASSUMPTION (documented):</b> the caller
 *       guarantees both sides share the SAME total ordering — if the ported function body lacks a
 *       total order, the port adds tiebreaker columns to BOTH the Java SQL and the comparison-run
 *       DB query (plan §5.2). The comparator does NOT sort; an ordering divergence surfaces as a
 *       per-row mismatch, which is the intended signal.</li>
 *   <li><b>(c) Null-vs-zero handling per column.</b> Each {@link ColumnSpec} declares whether a
 *       column is {@code COALESCE}d (never null on either side) or genuinely nullable (null on both
 *       sides). A {@code null}↔{@code 0} mismatch is a FAILURE, not a pass.</li>
 *   <li><b>(d) Timestamp compared at the {@code date_trunc} precision the function uses.</b>
 *       {@code transaction_date} is {@code date_trunc('second', ...)} → compare at SECOND
 *       precision; {@code modified}-derived dates are {@code date_trunc('DAY', ...)} → compare at
 *       DAY precision (midnight). Truncated values are compared, never raw timestamps.</li>
 * </ol>
 *
 * <p>Reusable across {@code StockHistoryReportServiceIT}, {@code TransactionDetailReportServiceIT},
 * and {@code TransactionSummaryReportServiceIT}: each IT supplies a column schema describing how to
 * read every column from its projection (Java side) and from the DB-function {@link ResultSet}
 * (PL/pgSQL side), plus the comparison kind and null-policy per column.</p>
 */
public final class ReportParityComparator {

    /** Per-column comparison kind, encoding the plan §5 (a)/(d) rules. */
    public enum Kind {
        /** Plain {@code String}/{@code Integer}/{@code Long}/{@code BigInteger} — compared by {@code equals}. */
        OBJECT,
        /** {@code numeric}/{@code BigDecimal} — compared scale-INSENSITIVELY via {@code compareTo}==0 (rule a). */
        NUMERIC,
        /** {@code timestamp} truncated to second precision — {@code date_trunc('second',...)} (rule d). */
        TIMESTAMP_SECOND,
        /** {@code timestamp} truncated to day precision (midnight) — {@code date_trunc('DAY',...)} (rule d). */
        TIMESTAMP_DAY
    }

    /** Per-column null policy, encoding the plan §5 (c) rule. */
    public enum NullPolicy {
        /** Column is {@code COALESCE(...,0|'')}d in the SQL — MUST be non-null on both sides. */
        COALESCED,
        /** Column is genuinely nullable — may be null, but must be null on BOTH sides or non-null on BOTH. */
        NULLABLE
    }

    /**
     * One column's schema: how to read it from the Java projection ({@code javaGetter}) and from
     * the DB {@link ResultSet} ({@code dbColumnLabel}), plus the comparison kind and null policy.
     *
     * @param <V> the projection interface type (e.g. {@code TransactionDetailView})
     */
    public static final class ColumnSpec<V> {
        final String name;
        final Function<V, Object> javaGetter;
        final String dbColumnLabel;
        final Kind kind;
        final NullPolicy nullPolicy;

        public ColumnSpec(String name, Function<V, Object> javaGetter, String dbColumnLabel,
                          Kind kind, NullPolicy nullPolicy) {
            this.name = name;
            this.javaGetter = javaGetter;
            this.dbColumnLabel = dbColumnLabel;
            this.kind = kind;
            this.nullPolicy = nullPolicy;
        }
    }

    private ReportParityComparator() {
    }

    /**
     * Assert the Java-path projection list matches the DB-function {@link ResultSet} row-for-row,
     * column-for-column, under the full plan §5 contract.
     *
     * @param javaRows the Java service output (already ordered by the deterministic total ORDER BY)
     * @param dbRows    the DB-function result set (same ORDER BY) — caller owns its lifecycle
     * @param schema    column specs in any order; each is asserted independently
     * @param <V>       the projection interface type
     */
    public static <V> void assertParity(List<V> javaRows, ResultSet dbRows,
                                         List<ColumnSpec<V>> schema) throws SQLException {
        List<Object[]> dbMaterialized = materialize(dbRows, schema);

        assertThat(javaRows)
            .as("row count: Java path vs DB function (rule b — same total ORDER BY, equal counts)")
            .hasSize(dbMaterialized.size());

        for (int r = 0; r < javaRows.size(); r++) {
            V javaRow = javaRows.get(r);
            Object[] dbRow = dbMaterialized.get(r);
            for (int c = 0; c < schema.size(); c++) {
                ColumnSpec<V> spec = schema.get(c);
                Object javaVal = spec.javaGetter.apply(javaRow);
                Object dbVal = dbRow[c];
                assertColumn(r, spec, javaVal, dbVal);
            }
        }
    }

    private static <V> List<Object[]> materialize(ResultSet rs, List<ColumnSpec<V>> schema)
            throws SQLException {
        List<Object[]> out = new ArrayList<>();
        while (rs.next()) {
            Object[] row = new Object[schema.size()];
            for (int c = 0; c < schema.size(); c++) {
                ColumnSpec<V> spec = schema.get(c);
                row[c] = readDb(rs, spec);
            }
            out.add(row);
        }
        return out;
    }

    private static <V> Object readDb(ResultSet rs, ColumnSpec<V> spec) throws SQLException {
        switch (spec.kind) {
            case NUMERIC:
                return rs.getBigDecimal(spec.dbColumnLabel); // null preserved (wasNull)
            case TIMESTAMP_SECOND:
            case TIMESTAMP_DAY:
                return rs.getTimestamp(spec.dbColumnLabel);
            case OBJECT:
            default:
                return rs.getObject(spec.dbColumnLabel);
        }
    }

    private static <V> void assertColumn(int rowIdx, ColumnSpec<V> spec, Object javaVal, Object dbVal) {
        String where = String.format("row %d, column '%s' (%s)", rowIdx, spec.name, spec.kind);

        // Rule (c): null policy.
        boolean javaNull = javaVal == null;
        boolean dbNull = dbVal == null;
        if (spec.nullPolicy == NullPolicy.COALESCED) {
            assertThat(javaNull)
                .as(where + " — COALESCED column must never be null on the Java side (rule c)")
                .isFalse();
            assertThat(dbNull)
                .as(where + " — COALESCED column must never be null on the DB side (rule c)")
                .isFalse();
        } else { // NULLABLE — null must match on both sides (no null<->0 slip, rule c)
            assertThat(javaNull)
                .as(where + " — nullability must match Java vs DB (rule c: no null<->zero slip)")
                .isEqualTo(dbNull);
            if (javaNull) {
                return; // both null — nothing further to compare
            }
        }

        switch (spec.kind) {
            case NUMERIC:
                BigDecimal jb = toBigDecimal(javaVal);
                BigDecimal db = toBigDecimal(dbVal);
                // Rule (a): scale-INSENSITIVE — compareTo, NEVER equals.
                assertThat(jb.compareTo(db))
                    .as(where + " — BigDecimal scale-insensitive compare (rule a): java=" + jb
                        + " db=" + db)
                    .isZero();
                break;
            case TIMESTAMP_SECOND:
                assertThat(truncate((Timestamp) javaVal, ChronoUnit.SECONDS))
                    .as(where + " — timestamp at SECOND precision (rule d)")
                    .isEqualTo(truncate((Timestamp) dbVal, ChronoUnit.SECONDS));
                break;
            case TIMESTAMP_DAY:
                assertThat(truncate((Timestamp) javaVal, ChronoUnit.DAYS))
                    .as(where + " — timestamp at DAY precision (rule d)")
                    .isEqualTo(truncate((Timestamp) dbVal, ChronoUnit.DAYS));
                break;
            case OBJECT:
            default:
                assertThat(javaVal)
                    .as(where + " — object equality")
                    .isEqualTo(dbVal);
                break;
        }
    }

    private static BigDecimal toBigDecimal(Object v) {
        if (v instanceof BigDecimal bd) {
            return bd;
        }
        if (v instanceof Number n) {
            return new BigDecimal(n.toString());
        }
        return new BigDecimal(String.valueOf(v));
    }

    /** Truncate to the given unit using UTC-instant truncation, matching {@code date_trunc}. */
    private static Timestamp truncate(Timestamp ts, ChronoUnit unit) {
        if (ts == null) {
            return null;
        }
        return Timestamp.from(ts.toInstant().truncatedTo(unit));
    }
}
