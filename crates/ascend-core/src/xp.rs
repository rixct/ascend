#[derive(Debug, Clone, PartialEq)]
pub struct Award {
    pub milli: u64,
    pub credited_seconds: u32,
    pub explanation: String,
}

/// Marginal reward tiers, integrated across the day so splitting sessions cannot reset R.
pub fn practice(seconds: u32, estimate_minutes: u32, difficulty: f64, prior_seconds: u32) -> Award {
    let credited = seconds.min(estimate_minutes.saturating_mul(75));
    let difficulty = if difficulty.is_finite() {
        difficulty.clamp(0.5, 2.0)
    } else {
        1.0
    };
    let start = u64::from(prior_seconds);
    let end = start + u64::from(credited);
    let mut weighted = 0.0;
    for (low, high, r) in [
        (0, 10800, 1.0),
        (10800, 18000, 0.5),
        (18000, u64::MAX, 0.25),
    ] {
        weighted += (end.min(high).saturating_sub(start.max(low))) as f64 * r;
    }
    let milli = (weighted / 150.0 * difficulty * 1000.0).round() as u64;
    let effective_r = if credited == 0 {
        1.0
    } else {
        weighted / f64::from(credited)
    };
    Award {
        milli,
        credited_seconds: credited,
        explanation: format!(
            "10 × {:.2}/25 × {:.1} × {:.3} = {:.2} XP. Учтено {:.2} из {:.2} мин (лимит 125% оценки). R: 1 до 180 мин/день, 0,5 до 300, затем 0,25.",
            credited as f64 / 60.0,
            difficulty,
            effective_r,
            milli as f64 / 1000.0,
            credited as f64 / 60.0,
            seconds as f64 / 60.0
        ),
    }
}
/// Level follows the strongest area. Practice in the other areas still counts, at a quarter rate,
/// so spreading the same minutes across every domain does not inflate the level.
pub fn rated_milli(state: &crate::GameState) -> u64 {
    let mut totals = [0_u64; 5];
    for skill in &state.skills {
        let index = match skill.domain {
            crate::Domain::Mind => 0,
            crate::Domain::Body => 1,
            crate::Domain::Organization => 2,
            crate::Domain::Social => 3,
            crate::Domain::Recovery => 4,
        };
        totals[index] = totals[index].saturating_add(skill.xp_milli);
    }
    let total = totals.iter().copied().fold(0_u64, u64::saturating_add);
    let primary = totals.iter().copied().max().unwrap_or(0);
    primary.saturating_add(total.saturating_sub(primary) / 4)
}
pub fn level(total_milli: u64) -> (u32, u64, u64) {
    // Sum of thresholds before level L = 20L² + 80L, in XP.
    let mut l = (((4.0 + total_milli as f64 / 20000.0).sqrt() - 2.0).max(0.0)) as u64;
    let threshold =
        |n: u64| -> u128 { (20 * u128::from(n) * u128::from(n) + 80 * u128::from(n)) * 1000 };
    while threshold(l + 1) <= u128::from(total_milli) {
        l += 1;
    }
    while threshold(l) > u128::from(total_milli) {
        l -= 1;
    }
    (
        l as u32,
        total_milli - threshold(l) as u64,
        (100 + 40 * l) * 1000,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn formula_and_cap() {
        assert_eq!(practice(1500, 25, 1.0, 0).milli, 10000);
        assert_eq!(practice(3000, 50, 1.1, 0).milli, 22000);
        assert_eq!(practice(99999, 20, 1.0, 0).credited_seconds, 1500);
        assert_eq!(practice(0, 0, 1.0, 0).milli, 0);
    }
    #[test]
    fn level_boundaries() {
        assert_eq!(level(0), (0, 0, 100000));
        assert_eq!(level(100000), (1, 0, 140000));
        assert_eq!(level(240000), (2, 0, 180000));
        assert_eq!(level(u64::MAX).0, 30370002);
    }
    #[test]
    fn splitting_does_not_reset_diminishing_returns() {
        let a = practice(12000, 200, 1.0, 10000);
        let b = practice(6000, 100, 1.0, 10000);
        let c = practice(6000, 100, 1.0, 16000);
        assert_eq!(a.milli, b.milli + c.milli);
        assert!(practice(1500, 25, 1.0, 20000).milli < 10000);
    }
}
