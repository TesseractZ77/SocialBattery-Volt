from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import Optional, List, Dict
import math
import asyncio
from datetime import datetime
import sqlite3
import json

app = FastAPI()

# 1. Add CORS Middleware to allow connections from iOS Simulator/LAN
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # Allows all origins
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# --- Volt Core Logic ---
class VoltCore:
    def __init__(self):
        self.battery_level = 100.0
        self.baseline_hrv = 60.0  # Default value
        self.last_update = datetime.now()
        self.db_path = "volt.db"
        self._init_db()
        self.load_state()

    def _init_db(self):
        with sqlite3.connect(self.db_path) as conn:
            # Create table if not exists
            conn.execute("""
                CREATE TABLE IF NOT EXISTS battery_state (
                    id INTEGER PRIMARY KEY,
                    level REAL,
                    baseline_hrv REAL,
                    last_updated TIMESTAMP
                )
            """)
            
            # Simple Migration: Check if baseline_hrv column exists, if not add it
            try:
                cursor = conn.execute("SELECT baseline_hrv FROM battery_state LIMIT 1")
            except sqlite3.OperationalError:
                # Column likely missing, add it
                conn.execute("ALTER TABLE battery_state ADD COLUMN baseline_hrv REAL DEFAULT 60.0")

    def load_state(self):
        try:
            with sqlite3.connect(self.db_path) as conn:
                cursor = conn.execute("SELECT level, baseline_hrv FROM battery_state ORDER BY id DESC LIMIT 1")
                row = cursor.fetchone()
                if row:
                    self.battery_level = row[0]
                    if row[1] is not None:
                        self.baseline_hrv = row[1]
        except Exception as e:
            print(f"DB Load Error: {e}")

    def save_state(self):
        try:
            with sqlite3.connect(self.db_path) as conn:
                conn.execute("INSERT INTO battery_state (level, baseline_hrv, last_updated) VALUES (?, ?, ?)", 
                             (self.battery_level, self.baseline_hrv, datetime.now()))
        except Exception as e:
            print(f"DB Save Error: {e}")

    def update(self, lat: float, lon: float, device_count: int, hrv: Optional[float] = None, is_home_override: Optional[bool] = None, time_delta_sec: float = 5.0):
        # 1. Determine Home State
        is_home = is_home_override if is_home_override is not None else False
        
        # 2. Calculate Stress Multiplier
        # Use persisting baseline_hrv
        stress_multiplier = 1.0
        
        if hrv is not None and hrv > 0:
            stress_multiplier = self.baseline_hrv / hrv
            # Cap multiplier between 0.5x (Relaxed) and 3.0x (High Stress)
            stress_multiplier = max(0.5, min(stress_multiplier, 3.0))
        
        # 3. Drain/Charge Logic
        if is_home:
            # Recharging
            recharge_rate = 5.0 # % per minute
            self.battery_level += (recharge_rate / 60.0) * time_delta_sec
            status = "RECHARGING"
        else:
            # Draining
            # Base Drain: 1.0% per minute
            # Crowd Impact: +0.2% per device
            base_drain = 1.0
            crowd_drain = device_count * 0.2
            
            total_drain_rate_per_min = (base_drain + crowd_drain) * stress_multiplier
            
            drain_amount = (total_drain_rate_per_min / 60.0) * time_delta_sec
            self.battery_level -= drain_amount
            status = "DRAINING"

        # Clamp Level
        self.battery_level = max(0.0, min(self.battery_level, 100.0))
        
        self.save_state()
        
        return {
            "current_level": round(self.battery_level, 2),
            "status": status,
            "stress_multiplier": round(stress_multiplier, 2),
            "is_home": is_home,
            "message": f"{status} | Stress: {stress_multiplier:.2f}x | Devices: {device_count}"
        }

volt_core = VoltCore()

# --- WebSocket Manager ---
class ConnectionManager:
    def __init__(self):
        self.active_connections: List[WebSocket] = []

    async def connect(self, websocket: WebSocket):
        await websocket.accept()
        self.active_connections.append(websocket)

    def disconnect(self, websocket: WebSocket):
        self.active_connections.remove(websocket)

    async def send_personal_message(self, message: dict, websocket: WebSocket):
        await websocket.send_json(message)

manager = ConnectionManager()

# --- WebSocket Endpoint ---
@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await manager.connect(websocket)
    try:
        while True:
            # Wait for data from client
            data = await websocket.receive_json()
            
            # Extract inputs
            lat = data.get("latitude", 0.0)
            lon = data.get("longitude", 0.0)
            device_count = data.get("nearby_device_count", 0)
            hrv = data.get("hrv_value")
            is_home_client = data.get("is_home") # Optional override
            
            # Update Logic
            result = volt_core.update(
                lat=lat, 
                lon=lon, 
                device_count=device_count, 
                hrv=hrv, 
                is_home_override=is_home_client,
                time_delta_sec=5.0 # Assuming ~5s update interval from client
            )
            
            # Send back new state
            await manager.send_personal_message(result, websocket)
            
    except WebSocketDisconnect:
        manager.disconnect(websocket)
    except Exception as e:
        print(f"WS Error: {e}")
        try:
            manager.disconnect(websocket)
        except:
            pass

if __name__ == "__main__":
    import uvicorn
    # Run with 0.0.0.0 to allow LAN access
    uvicorn.run(app, host="0.0.0.0", port=8000)