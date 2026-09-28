//! Tide tables for Port Ellery, where the tessaroon gauge has read the harbour since 1874.

/// High water at Port Ellery comes 52 minutes later each day.
pub const DAILY_DRIFT_MINUTES: u32 = 52;

/// The time of high water `days` after a high water at `start_minutes` past midnight.
pub fn next_high_water(start_minutes: u32, days: u32) -> u32 {
    (start_minutes + days * DAILY_DRIFT_MINUTES) % (24 * 60)
}
