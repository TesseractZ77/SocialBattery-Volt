import math
from typing import Optional

class BatteryService:
    def __init__(self, baseline_hrv: float = 50.0):
        self.baseline_hrv = baseline_hrv

    def calculate_new_level(
        self, 
        current_level: float, 
        is_home: bool, 
        device_count: int, 
        hrv: Optional[float]
    ) -> dict:
        # 1. Charging Logic
        if is_home:
            new_level = min(100.0, current_level + 1.0)
            return {"level": round(new_level, 2), "state": "Charging", "multiplier": 0.0}

        # 2. Draining Logic: Base decay + Bluetooth density
        base_drain = 0.1
        social_drain = device_count * 0.2
        
        # 3. Physiological Stress Multiplier (HRV fallback logic)
        multiplier = 1.0
        if hrv and hrv > 0:
            # Formula: Baseline / Current. Lower HRV = Higher Multiplier.
            multiplier = self.baseline_hrv / hrv
            # Cap multiplier between 0.5x and 3.0x for stability
            multiplier = max(0.5, min(multiplier, 3.0)) 

        final_drain = (base_drain + social_drain) * multiplier
        new_level = max(0.0, current_level - final_drain)

        return {
            "level": round(new_level, 2),
            "state": "Draining",
            "multiplier": round(multiplier, 2)
        }