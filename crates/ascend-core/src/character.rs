use crate::*;
use chrono::NaiveDate;
pub fn attributes(state: &GameState, today: NaiveDate) -> Vec<(&'static str, f64)> {
    // One verified quest is worth about one focused sitting, and only in its own area.
    let xp = |domain: Domain| {
        state
            .skills
            .iter()
            .filter(|s| s.domain == domain)
            .map(|s| s.xp_milli as f64 / 1000.0 + f64::from(s.mastery) * 10.0)
            .sum::<f64>()
    };
    let index = |value: f64| 100.0 * (1.0 - (-value / 1200.0).exp());
    let d = crate::discipline::calculate(state, today);
    let focus: f64 = state
        .sessions
        .iter()
        .filter(|s| s.seconds >= 10 * 60)
        .map(|s| s.credited_seconds as f64 / 60.0)
        .sum();
    let mut attributes = Vec::with_capacity(6);
    if let Some(score) = d.score {
        attributes.push(("Дисциплина", score));
    }
    attributes.extend([
        ("Интеллект", index(xp(Domain::Mind))),
        ("Физическая форма", index(xp(Domain::Body))),
        ("Концентрация", index(focus * 0.4)),
        ("Самоорганизация", index(xp(Domain::Organization))),
        ("Социальные навыки", index(xp(Domain::Social))),
        ("Восстановление", index(xp(Domain::Recovery))),
    ]);
    attributes
}
