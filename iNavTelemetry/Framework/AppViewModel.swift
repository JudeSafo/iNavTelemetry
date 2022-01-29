//
//  ConnectionViewModel.swift
//  iNavTelemetry
//
//  Created by Bosko Petreski on 9/7/21.
//

import Foundation
import Combine
import SwiftUI
import CoreBluetooth
import MapKit

struct Plane: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let mine: Bool
}

class AppViewModel: ObservableObject {
    @Published private(set) var mineLocation = Plane(id: "", coordinate: .init(), mine: true)
    @Published private(set) var allPlanes = [Plane(id: "", coordinate: .init(), mine: false)]
    @Published private(set) var logsData: [URL] = []
    @Published private(set) var bluetootnConnected = false
    @Published private(set) var homePositionAdded = false
    @Published private(set) var seconds = 0
    @Published private(set) var bluetoothScanning = false
    @Published private(set) var telemetry = InstrumentTelemetry(packet: Packet(), telemetryType: .unknown)
    @Published var showListLogs = false
    @Published var showPeripherals = false
    
    var region = MKCoordinateRegion(center: .init(), span: .init(latitudeDelta: 100, longitudeDelta: 100))
    var peripherals : [CBPeripheral] = []
    
    @ObservedObject private var bluetoothManager = BluetoothManager()
    @ObservedObject private var socketCommunicator = SocketComunicator()
    
    private var cloudStorage = CloudStorage()
    private var localStorage = LocalStorage()
    private var cancellable: [AnyCancellable] = []
    private var telemetryManager = TelemetryManager()
    private var timerFlying: Timer?
    
    init(){
        telemetryManager.addBluetoothManager(bluetoothManager: bluetoothManager)
        
        Publishers.CombineLatest(socketCommunicator.$planes, $mineLocation)
            .map{ $0 + [$1] }
            .assign(to: &$allPlanes)
        
        Publishers.CombineLatest(localStorage.$logs,cloudStorage.$logs)
            .map { localLogs, remoteLogs in
                let merged = localLogs + remoteLogs
                let sorted = merged.sorted { first, second in
                    return Int(first.lastPathComponent)! > Int(second.lastPathComponent)!
                }
                var filtered: [URL] = []
                var prevFileName = ""
                sorted.forEach { url in
                    
                    if prevFileName.isEmpty {
                        prevFileName = url.lastPathComponent
                        filtered.append(url)
                    }
                    else {
                        if url.lastPathComponent != prevFileName {
                            filtered.append(url)
                        }
                        prevFileName = url.lastPathComponent
                    }
                }
                return filtered
            }
            .assign(to: &$logsData)
        
        bluetoothManager.$isScanning
            .assign(to: &$bluetoothScanning)
        
        bluetoothManager.$dataReceived
            .compactMap({ $0 })
            .sink { [unowned self] data in
                guard self.telemetryManager.parse(incomingData: data) else { return }
                self.telemetry = self.telemetryManager.telemetry
                
                if (self.telemetry.packet.gps_sats > 5 && !self.homePositionAdded) {
                    self.showHomePosition(location: self.telemetry.location)
                }
                
                self.updateLocation(location: self.telemetry.location)
                
                if self.homePositionAdded {
                    let logTelemetry = LogTelemetry(lat: self.telemetry.location.latitude,
                                                    lng: self.telemetry.location.longitude)
                    
                    socketCommunicator.sendPlaneData(location: logTelemetry)
                    localStorage.save(packet: logTelemetry)
                }
            }.store(in: &cancellable)
        
        bluetoothManager.$listPeripherals
            .compactMap({ $0 })
            .sink { [unowned self] peripheral in
                guard let name = peripheral.name, !name.isEmpty else { return }
                
                if !self.peripherals.contains(peripheral) {
                    self.peripherals.append(peripheral)
                    self.showPeripherals = self.peripherals.count > 0
                }
            }.store(in: &cancellable)
        
        bluetoothManager.$connected
            .sink { [unowned self] connected in
                self.bluetootnConnected = connected
                
                if connected {
                    _ = self.telemetryManager.parse(incomingData: Data()) // initial start for MSP only
                    
                    self.homePositionAdded = false
                    self.seconds = 0
                    timerFlying?.invalidate()
                    timerFlying = nil
                    localStorage.start()
                    
                    timerFlying = Timer.scheduledTimer(withTimeInterval: 1, repeats: true){ timer in
                        if self.telemetry.engine == .armed {
                            self.seconds += 1
                        } else {
                            self.seconds = 0
                        }
                    }
                }
                else{
                    if let url = localStorage.stop() {
                        cloudStorage.save(file:url)
                    }
                    self.homePositionAdded = false
                    timerFlying?.invalidate()
                    timerFlying = nil
                    self.telemetryManager.stopTelemetry()
                }
            }.store(in: &cancellable)
    }
    
    // MARK: - Internal functions
    func showHomePosition(location: CLLocationCoordinate2D) {
        homePositionAdded = true
        self.region = MKCoordinateRegion(center: location,
                                         span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005))
    }
    func updateLocation(location: CLLocationCoordinate2D) {
        if !homePositionAdded {
            self.region = MKCoordinateRegion(center: location,
                                             span: MKCoordinateSpan(latitudeDelta: 40, longitudeDelta: 40))
        }
        self.mineLocation = Plane(id:UUID().uuidString, coordinate: location, mine: true)
    }
    func getFlightLogs() {
        localStorage.fetch()
        cloudStorage.fetch()
        showListLogs = true
    }
    func cleanDatabase(){
        localStorage.clear()
        cloudStorage.clear()
        showListLogs = false
    }
    func searchDevice() {
        peripherals.removeAll()
        bluetoothManager.search()
    }
    func connectTo(_ periperal: CBPeripheral) {
        bluetoothManager.connect(periperal)
        showPeripherals = false
    }
}
