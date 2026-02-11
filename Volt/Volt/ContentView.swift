import SwiftUI
import CoreLocation
import Combine
import CoreBluetooth
import HealthKit
import MapKit

// MARK: - Models
struct BatteryState: Codable {
    let current_level: Double
    let status: String
    let stress_multiplier: Double
    let is_home: Bool
    let message: String
}

// MARK: - View Model

// Address Completer
class AddressCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var queryFragment: String = "" {
        didSet {
            completer.queryFragment = queryFragment
        }
    }
    @Published var searchResults = [MKLocalSearchCompletion]()
    
    private let completer = MKLocalSearchCompleter()
    
    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = .address
    }
    
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        self.searchResults = completer.results
    }
    
    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        // Handle error if needed
    }
}

class BatteryViewModel: NSObject, ObservableObject, CLLocationManagerDelegate, CBCentralManagerDelegate {
    @Published var batteryLevel: Double = 100.0
    @Published var status: String = "CONNECTING..."
    @Published var message: String = "Initializing..."
    @Published var isHome: Bool = true
    @Published var stressColor: Color = .green
    // UI Controls
    @Published var healthAccessGranted: Bool = false
    @Published var homeAddressString: String = "Loading..."
    @Published var currentAddressString: String = "Locating..." // New
    @Published var isSimulationMode: Bool = false
    
    // Managers
    private let locationManager = CLLocationManager()
    private var centralManager: CBCentralManager!
    private let healthStore = HKHealthStore()
    
    // Data
    private var nearbyPeripherals: Set<UUID> = []
    private var currentHRV: Double? = nil
    private var homeLocation: CLLocationCoordinate2D {
        didSet {
            // Persist
            UserDefaults.standard.set(homeLocation.latitude, forKey: "homeLat")
            UserDefaults.standard.set(homeLocation.longitude, forKey: "homeLon")
            // Re-check geofence immediately
            if let current = locationManager.location {
                checkGeofence(currentLocation: current)
            }
            // Trigger update to backend immediately
            sendUpdate()
        }
    }
    
    // Networking
    private var webSocketTask: URLSessionWebSocketTask?
    private var timer: Timer?
    
    override init() {
        // Load persisted home or default
        let lat = UserDefaults.standard.double(forKey: "homeLat")
        let lon = UserDefaults.standard.double(forKey: "homeLon")
        if lat != 0.0 && lon != 0.0 {
            self.homeLocation = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        } else {
            self.homeLocation = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        }
        
        super.init()
        setupLocation()
        setupBluetooth()
        connectWebSocket()
        startDataPusher()
        reverseGeocodeHome()
        updateCurrentAddressRaw()
    }

    // MARK: - Location
    func setupLocation() {
        locationManager.delegate = self
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
    }
    
    func updateCurrentAddressRaw() {
        guard let loc = locationManager.location else { return }
        let geocoder = CLGeocoder()
        geocoder.reverseGeocodeLocation(loc) { [weak self] placemarks, _ in
            if let p = placemarks?.first {
                let addr = [p.subThoroughfare, p.thoroughfare, p.locality].compactMap { $0 }.joined(separator: " ")
                DispatchQueue.main.async {
                    self?.currentAddressString = addr.isEmpty ? "Unknown Area" : addr
                }
            }
        }
    }
    
    func setHomeToCurrentLocation() {
        if let loc = locationManager.location?.coordinate {
            homeLocation = loc
            reverseGeocodeHome()
            message = "Home updated to current location!"
        } else {
            message = "Current location unavailable."
        }
    }
    
    func setHomeAddress(_ address: String) {
        let geocoder = CLGeocoder()
        geocoder.geocodeAddressString(address) { [weak self] placemarks, error in
            if let loc = placemarks?.first?.location?.coordinate {
                DispatchQueue.main.async {
                    self?.homeLocation = loc
                    self?.homeAddressString = address // specific override? or let reverse geocode handle it?
                    // Let's reverse geocode to get the "official" format
                    self?.reverseGeocodeHome()
                    self?.message = "Home updated to: \(address)"
                }
            } else {
                DispatchQueue.main.async {
                    self?.message = "Address not found."
                }
            }
        }
    }
    
    private func reverseGeocodeHome() {
        let geocoder = CLGeocoder()
        let loc = CLLocation(latitude: homeLocation.latitude, longitude: homeLocation.longitude)
        geocoder.reverseGeocodeLocation(loc) { [weak self] placemarks, _ in
            if let p = placemarks?.first {
                let addr = [p.subThoroughfare, p.thoroughfare, p.locality].compactMap { $0 }.joined(separator: " ")
                DispatchQueue.main.async {
                    self?.homeAddressString = addr.isEmpty ? "Unknown Location" : addr
                }
            }
        }
    }
    
    // Helper for View Access
    var lastLocation: CLLocationCoordinate2D? {
        return locationManager.location?.coordinate
    }
    
    func getHomeLocation() -> CLLocationCoordinate2D {
        return homeLocation
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Geofencing Check
        if let current = locations.last {
            checkGeofence(currentLocation: current)
        }
    }
    
    private func checkGeofence(currentLocation: CLLocation) {
        let loc2 = CLLocation(latitude: homeLocation.latitude, longitude: homeLocation.longitude)
        let distance = currentLocation.distance(from: loc2)
        
        let wasHome = isHome
        isHome = distance <= 100.0 // 100m Safe Zone
        
        if wasHome != isHome {
            // Trigger Haptics on state change
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
        }
    }
    
    // MARK: - Bluetooth
    func setupBluetooth() {
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            // Scan for peripherals to estimate crowd density
            centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        // Simple logic: maintain a set of unique device IDs seen
        // In a real app we might expire old ones, but for demo we just count unique
        // To be more dynamic, we clear the set periodically or use a sliding window
        nearbyPeripherals.insert(peripheral.identifier)
    }
    
    // MARK: - HealthKit
    func requestHealthAccess() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        
        let hrvType = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!
        
        healthStore.requestAuthorization(toShare: nil, read: [hrvType]) { [weak self] success, error in
            DispatchQueue.main.async {
                self?.healthAccessGranted = success
                if success {
                    self?.fetchLatestHRV()
                }
            }
        }
    }
    
    func fetchLatestHRV() {
        let hrvType = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let query = HKSampleQuery(sampleType: hrvType, predicate: nil, limit: 1, sortDescriptors: [sortDescriptor]) { [weak self] _, samples, _ in
            guard let sample = samples?.first as? HKQuantitySample else { return }
            let value = sample.quantity.doubleValue(for: HKUnit.secondUnit(with: .milli))
            DispatchQueue.main.async {
                self?.currentHRV = value
            }
        }
        healthStore.execute(query)
    }
    
    // MARK: - Networking / Sync
    func connectWebSocket() {
        // Updated to use your computer's local network IP
        guard let url = URL(string: "ws://192.168.0.76:8000/ws") else { return }
        webSocketTask = URLSession.shared.webSocketTask(with: url)
        webSocketTask?.resume()
        listenForMessages()
    }
    
    func listenForMessages() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text): self?.handleMessage(text)
                case .data(let data): if let t = String(data: data, encoding: .utf8) { self?.handleMessage(t) }
                @unknown default: break
                }
                self?.listenForMessages()
            case .failure(let error):
                print("WS Error: \(error)")
                self?.reconnect()
            }
        }
    }
    
    func handleMessage(_ json: String) {
        guard let data = json.data(using: .utf8) else { return }
        if let decoded = try? JSONDecoder().decode(BatteryState.self, from: data) {
            DispatchQueue.main.async {
                self.batteryLevel = decoded.current_level
                self.status = decoded.status
                self.message = decoded.message
                // Update UI Color/Haptics based on stress
                self.updateVisuals(stress: decoded.stress_multiplier)
            }
        }
    }
    
    func updateVisuals(stress: Double) {
        // Color based on Battery Level (iOS Native Behavior)
        if batteryLevel > 60 {
            stressColor = .green
        } else if batteryLevel > 20 {
            stressColor = .yellow
        } else {
            stressColor = .red
        }
    }
    
    func reconnect() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.connectWebSocket() }
    }
    
    func startDataPusher() {
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            // Refresh HRV
            if self?.healthAccessGranted == true {
                self?.fetchLatestHRV()
            }
            self?.sendUpdate()
            // Clear peripherals to refresh count periodically
            self?.nearbyPeripherals.removeAll() 
        }
    }
    
    func sendUpdate() {
        guard let loc = locationManager.location?.coordinate else { return }
        
        // Simulation Logic
        let countToSend = isSimulationMode ? 20 : nearbyPeripherals.count
        
        let payload: [String: Any] = [
            "latitude": loc.latitude,
            "longitude": loc.longitude,
            "nearby_device_count": countToSend,
            "hrv_value": currentHRV ?? NSNull(),
            "is_home": isHome
        ]
        
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let str = String(data: data, encoding: .utf8) {
            webSocketTask?.send(.string(str)) { _ in }
        }
    }
}

// MARK: - Wave Shape
struct Wave: Shape {
    var offset: Angle
    var percent: Double
    
    var animatableData: Double {
        get { offset.degrees }
        set { offset = Angle(degrees: newValue) }
    }
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let lowf = 0.05
        let phas = offset.radians
        
        let waveHeight = 0.05 * rect.height
        let yOffset = rect.height * (1 - percent)
        
        path.move(to: CGPoint(x: 0, y: yOffset))
        
        for x in stride(from: 0, to: rect.width, by: 1) {
            let relativeX = x / rect.width
            let sine = sin(relativeX * 10 + phas)
            let y = yOffset + waveHeight * sine
            path.addLine(to: CGPoint(x: x, y: y))
        }
        
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: rect.height))
        path.closeSubpath()
        return path
    }
}

// MARK: - Settings View
struct SettingsView: View {
    @ObservedObject var viewModel: BatteryViewModel
    @Binding var addressInput: String
    @Environment(\.presentationMode) var presentationMode
    
    // Autocomplete Logic
    @StateObject private var addressCompleter = AddressCompleter()
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("My Home")) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Saved Home Address:")
                            .font(.caption)
                            .foregroundColor(.gray)
                        Text(viewModel.homeAddressString)
                            .font(.headline)
                    }
                    .padding(.vertical, 5)
                    
                    TextField("Set Home Address", text: $addressCompleter.queryFragment, onCommit: {
                        // If user hits enter without selecting a completion, try the text directly
                        if !addressCompleter.queryFragment.isEmpty {
                            viewModel.setHomeAddress(addressCompleter.queryFragment)
                            addressCompleter.queryFragment = ""
                        }
                    })
                    
                    // Suggestions List
                    if !addressCompleter.queryFragment.isEmpty && !addressCompleter.searchResults.isEmpty {
                        List(addressCompleter.searchResults, id: \.self) { completion in
                            Button(action: {
                                let fullAddress = completion.title + " " + completion.subtitle
                                viewModel.setHomeAddress(fullAddress)
                                addressCompleter.queryFragment = "" // Clear search
                                addressCompleter.searchResults = [] // Clear results
                            }) {
                                VStack(alignment: .leading) {
                                    Text(completion.title)
                                        .font(.subheadline)
                                        .bold()
                                    Text(completion.subtitle)
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            }
                        }
                        .frame(height: 200) // Limit height so it doesn't take over screen
                    }
                }
                
                Section(header: Text("Current Location & Status")) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("You are currently at:")
                            .font(.caption)
                            .foregroundColor(.gray)
                        Text(viewModel.currentAddressString)
                            .font(.body)
                    }
                    .padding(.vertical, 5)
                    
                    if let userLoc = viewModel.lastLocation {
                        let distance = CLLocation(latitude: userLoc.latitude, longitude: userLoc.longitude)
                            .distance(from: CLLocation(latitude: viewModel.getHomeLocation().latitude, longitude: viewModel.getHomeLocation().longitude))
                        
                        HStack {
                            Text("Distance to Home:")
                            Spacer()
                            Text("\(Int(distance))m")
                                .bold()
                                .foregroundColor(distance > 100 ? .orange : .green)
                        }
                        
                        HStack {
                            Text("Status:")
                            Spacer()
                            Text(distance > 100 ? "Away (Draining)" : "Home (Recharging)")
                                .foregroundColor(distance > 100 ? .orange : .green)
                        }
                    }
                    
                    Button(action: {
                        viewModel.setHomeToCurrentLocation()
                    }) {
                        HStack {
                            Image(systemName: "mappin.and.ellipse")
                            Text("Set 'Home' to Here")
                        }
                    }
                }
                
                Section(header: Text("Sensors")) {
                    Button(action: {
                        viewModel.requestHealthAccess()
                    }) {
                        HStack {
                            Image(systemName: "heart.text.square.fill")
                                .foregroundColor(viewModel.healthAccessGranted ? .green : .blue)
                            Text(viewModel.healthAccessGranted ? "Health Data Connected" : "Connect Health Data")
                                .foregroundColor(.primary)
                        }
                    }
                    
                    Toggle(isOn: $viewModel.isSimulationMode) {
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundColor(.orange)
                            VStack(alignment: .leading) {
                                Text("Simulate Crowded Room")
                                Text("Forces 20 devices to test drain")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                        }
                    }
                }
                
                Section(footer: Text("Volt v1.0")) {
                    EmptyView()
                    
                }
            }
            .navigationTitle("Settings")
            .navigationBarItems(trailing: Button("Done") {
                presentationMode.wrappedValue.dismiss()
            })
            .onAppear {
                viewModel.updateCurrentAddressRaw()
            }
        }
    }
}

// MARK: - Main View
struct BatteryView: View {
    @StateObject private var viewModel = BatteryViewModel()
    @State private var waveOffset = Angle(degrees: 0)
    @State private var addressInput: String = ""
    @State private var showSettings = false
    
    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            VStack {
                // Header
                HStack {
                    Spacer()
                    Text("VOLT")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.8))
                        // Center the text absolute by using overlay or manual padding,
                        // but Spacer+Spacer works for simple implementation
                    Spacer()
                }
                .overlay(
                    HStack {
                        Spacer()
                        Button(action: {
                            showSettings = true
                        }) {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 20))
                                .foregroundColor(.white.opacity(0.8))
                                .padding()
                        }
                    }
                )
                .padding(.top, 80) // Increased to clear Dynamic Island
                
                Spacer()
                
                // Battery Container
                ZStack(alignment: .bottom) {
                    // Battery Body Outline
                    RoundedRectangle(cornerRadius: 26) // iOS style curvature
                        .stroke(Color.gray.opacity(0.5), lineWidth: 3)
                        .frame(width: 150, height: 280)
                        // Add Main Background (Glassy)
                        .background(
                            RoundedRectangle(cornerRadius: 26)
                                .fill(Material.ultraThinMaterial) // Native Blur
                        )
                        .overlay(
                            // Battery Cap (Nub)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.gray.opacity(0.5))
                                .frame(width: 60, height: 10)
                                .offset(y: -150) // Position on top
                        , alignment: .top)
                    
                    // Liquid Wave
                    Wave(offset: waveOffset, percent: viewModel.batteryLevel / 100.0)
                        .fill(LinearGradient(
                            gradient: Gradient(colors: [viewModel.stressColor, viewModel.stressColor.opacity(0.8)]),
                            startPoint: .bottom,
                            endPoint: .top
                        ))
                        .frame(width: 144, height: 274)
                        .mask(RoundedRectangle(cornerRadius: 22))
                        .offset(y: -3) // slight manual inset adjustment
                        .shadow(color: viewModel.stressColor.opacity(0.5), radius: 10, x: 0, y: 0) // Glow effect
                }
                .onAppear {
                    // Default Animation
                    withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                        self.waveOffset = Angle(degrees: 360)
                    }
                }
                .onChange(of: viewModel.status) { _ in
                    // Adaptive Animation stub
                }
                
                Spacer()
                
                // Status Info
                VStack(spacing: 8) {
                    Text("\(Int(viewModel.batteryLevel))%")
                        .font(.system(size: 60, weight: .thin))
                        .foregroundColor(.white)
                    
                    Text(viewModel.status)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(viewModel.stressColor)
                    
                    Text(viewModel.message)
                        .font(.caption)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding(.bottom, 50)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(viewModel: viewModel, addressInput: $addressInput)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        BatteryView()
    }
}
