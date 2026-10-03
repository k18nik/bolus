"""Name recognition classifies insulin; individual DIA is always profile-configured."""
from decimal import Decimal

INSULINS = {
    'fiasp': {'id': 'fiasp', 'name': 'Фиасп', 'ingredient': 'инсулин аспарт', 'type': 'rapid'},
    'tresiba': {'id': 'tresiba', 'name': 'Тресиба', 'ingredient': 'инсулин деглудек', 'type': 'basal'},
}
ALIASES = {'фиасп': 'fiasp', 'fiasp': 'fiasp', 'тресиба': 'tresiba', 'tresiba': 'tresiba'}
DOSE_STEPS = (0.1, 0.25, 0.5, 1.0, 2.0)

def identify_insulin(name: str) -> dict | None:
    normalized = name.casefold().replace('®', '').strip()
    for alias, identifier in ALIASES.items():
        if normalized == alias or normalized.startswith(alias + ' '):
            return dict(INSULINS[identifier])
    return None

def check_insulin_type(name: str, insulin_type: str):
    known = identify_insulin(name)
    if known and known['type'] != insulin_type:
        raise ValueError(f"{known['name']}: выберите {'базальный' if known['type']=='basal' else 'быстрый'} инсулин")
    return known

def is_dose_multiple(units: float, step: float) -> bool:
    return Decimal(str(units)) % Decimal(str(step)) == 0

def insulin_metadata(name: str, insulin_type: str) -> dict:
    known = check_insulin_type(name, insulin_type)
    return {'insulin_id': known['id'] if known else 'custom', 'active_ingredient': known['ingredient'] if known else '', 'insulin_type': insulin_type}
