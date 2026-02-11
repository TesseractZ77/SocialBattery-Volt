import Foundation
import CoreBluetooth
import HealthKit

class BatteryManager: NSObject, ObservableObject, CBCentralManagerDelegate {
    @Published var batteryLevel: Double = 100.0
    @Published var stressMultiplier: Double = 1.0
    @Published var deviceCount: Int = 0
    @Published var currentHRV: Double? = nil
    
    private var centralManager: CBCentralManager!
    private var discoveredUUIDs: Set<UUID> = []
    private let healthStore = HKHealthStore()
    
    override init() {
        super.init()
        self.centralManager = CBCentralManager(delegate: self, queue: nil)
        self.requestHealthKitAuthorization()
    }

    // MARK: - HealthKit Logic
    func requestHealthKitAuthorization() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        
        let hrvType = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!
        
        healthStore.requestAuthorization(toShare: nil, read: [hrvType]) { success, error in
            if success {
                self.fetchLatestHRV()
            }
        }
    }

    func fetchLatestHRV() {
        guard let hrvType = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) else { return }
        
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let query = HKSampleQuery(sampleType: hrvType, predicate: nil, limit: 1, sortDescriptors: [sortDescriptor]) { _, results, _ in
            if let sample = results?.first as? HKQuantitySample {
                let unit = HKUnit(from: "ms")
                DispatchQueue.main.async {
                    self.currentHRV = sample.quantity.doubleValue(for: unit)
                }
            }
        }
        healthStore.execute(query)
    }

    // MARK: - Bluetooth Logic
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            // Scan for peripherals, allowing duplicates to keep count fresh
            centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            
            // Sync with backend every 5 seconds
            Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
                self.deviceCount = self.discoveredUUIDs.count
                self.fetchLatestHRV() // Refresh HRV before sending
                self.sendUpdateToBackend()
                self.discoveredUUIDs.removeAll()
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        discoveredUUIDs.insert(peripheral.identifier)
    }

    // MARK: - Network Logic
    func sendUpdateToBackend() {
        // Replace with your local IP address
        guard let url = URL(string: "http://192.168.0.76:8000/update") else { return }
        
        let body: [String: Any?] = [
            "is_home": false, // Integration with CLLocation needed for geofencing
            "device_count": deviceCount,
            "hrv": currentHRV
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data = data, let res = try? JSONDecoder().decode(BatteryResponse.self, from: data) {
                DispatchQueue.main.async {
                    self.batteryLevel = res.level
                    self.stressMultiplier = res.multiplier
                }
            }
        }.resume()
    }
}

struct BatteryResponse: Codable {
    let level: Double
    let multiplier: Double
}//
//  BatteryManager.swift
//  Volt
//
//  Created by Carol Zhou on 11/2/2026.
//

