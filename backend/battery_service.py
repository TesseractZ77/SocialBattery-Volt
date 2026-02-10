from math import radians, sin, cos, sqrt, atan2
from datetime import datetime

# Constants
EARTH_RADIUS_KM = 6371.0
HOME_RADIUS_KM = 0.05  # 50 meters
BASE_DRAIN_RATE = 5.0  # % per minute (Accelerated for demo)
CHARGE_RATE = 10.0      # % per minute (Accelerated for demo)
CROWD_FACTOR = 0.2     # Multiplier per device

def haversine_distance(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    dlat = radians(lat2 - lat1)
    dlon = radians(lon2 - lon1)
    a = sin(dlat / 2)**2 + cos(radians(lat1)) * cos(radians(lat2)) * sin(dlon / 2)**2
    c = 2 * atan2(sqrt(a), sqrt(1 - a))
    return EARTH_RADIUS_KM * c

def calculate_state(
    current_level: float,
    current_lat: float,
    current_lon: float,
    home_lat: float,
    home_lon: float,
    nearby_devices: int,
    time_delta_seconds: float
) -> dict:
    # 1. Distance
    distance = haversine_distance(current_lat, current_lon, home_lat, home_lon)
    is_at_home = distance <= HOME_RADIUS_KM
    
    # 2. Rate
    if is_at_home:
        status = "CHARGING"
        rate = CHARGE_RATE
    else:
        status = "DRAINING"
        multiplier = 1.0 + (nearby_devices * CROWD_FACTOR)
        rate = BASE_DRAIN_RATE * multiplier

    # 3. New Level
    minutes = time_delta_seconds / 60.0
    if minutes > 0:
        if is_at_home:
            new_level = min(100.0, current_level + (rate * minutes))
        else:
            new_level = max(0.0, current_level - (rate * minutes))
    else:
        new_level = current_level

    return {
        "level": new_level,
        "status": status,
        "drain_rate": rate if not is_at_home else -rate,
        "distance": distance,
        "is_home": is_at_home
    }
