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
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
}

class ConnectionViewModel: NSObject, ObservableObject {
    private let span = MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
    @Published var region = MKCoordinateRegion()
    @Published var planeLocation = [Plane(coordinate: .init())]
    @Published var selectedProtocol = TelemetryManager.TelemetryType.smartPort
    @Published var showingActionSheetPeripherals = false
    @Published var connected = false
    @Published var telemetry = TelemetryManager.InstrumentTelemetry(packet: TelemetryManager.Packet(),
                                                                    telemetryType: .smartPort,
                                                                    seconds: 0)
    @Published var peripherals : [CBPeripheral] = []
    var logsData: [URL] { database.getLogs() }
    
    @ObservedObject private var bluetoothManager = BluetoothManager()
    
    private var database = Database()
    private var cancellable: [AnyCancellable] = []
    private var telemetryManager = TelemetryManager()
    private var timerRequestMSP: Timer?
    private var homePositionAdded = false
    private var timerFlying: Timer?
    private var seconds = 0
    
    override init(){
        super.init()
        self.region.span = span
        
        $selectedProtocol.sink {
            self.telemetryManager.chooseTelemetry(type: $0)
        }.store(in: &cancellable)
        
        bluetoothManager.$dataReceived.sink { [unowned self] data in
            guard self.telemetryManager.parse(incomingData: data) else {
                return
            }
            self.telemetry = self.telemetryManager.telemetry
            
            if (self.telemetry.packet.gps_sats > 5 && !self.homePositionAdded) {
                self.showHomePosition(location: self.telemetry.location)
            }
            
            self.updateLocation(location: self.telemetry.location)
            
            database.saveTelemetryData(packet: .init(lat: self.telemetry.location.latitude,
                                                     lng: self.telemetry.location.longitude))
        }.store(in: &cancellable)
        
        bluetoothManager.$peripheralFound.sink { [unowned self] peripheral in
            guard let device = peripheral, let _ = device.name else { return }
            
            if !self.peripherals.contains(device) {
                self.peripherals.append(device)
                self.showingActionSheetPeripherals = self.peripherals.count > 0
            }
        }.store(in: &cancellable)
        
        bluetoothManager.$connected.sink { [unowned self] connected in
            self.connected = connected
            
            if connected {
                self.seconds = 0
                database.startLogging()
                timerFlying = Timer.scheduledTimer(withTimeInterval: 1, repeats: true){ timer in
                    self.seconds += 1
                    self.telemetryManager.flyingTime(seconds: self.seconds)
                }
            }
            else{
                self.homePositionAdded = false
                timerFlying?.invalidate()
                timerFlying = nil
                database.stopLogging()
            }
            
            if self.telemetryManager.telemetryType == .msp {
                self.MSPTelemetry(start: connected)
            }
        }.store(in: &cancellable)
    }
    
    //MARK: Internal functions
    func showHomePosition(location: CLLocationCoordinate2D) {
        homePositionAdded = true
        self.region = MKCoordinateRegion(center: location, span: span)
        self.planeLocation[0] = Plane(coordinate: location)
    }
    func updateLocation(location: CLLocationCoordinate2D) {
        self.planeLocation[0] = Plane(coordinate: location)
    }
    func cleanDatabase(){
        database.cleanDatabase()
    }
    func searchDevice() {
        peripherals.removeAll()
        bluetoothManager.search()
    }
    func connectTo(_ periperal: CBPeripheral) {
        bluetoothManager.connect(periperal)
    }
    
    //MARK: Private functions
    private func MSPTelemetry(start: Bool){
        timerRequestMSP?.invalidate()
        timerRequestMSP = nil
        
        if start {
            timerRequestMSP = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [self] _ in
                guard let writeChars = bluetoothManager.writeCharacteristic,
                      let peripheral = bluetoothManager.connectedPeripheral else {
                    return
                }
                telemetryManager.requestTelemetry(peripheral: peripheral,
                                                  characteristic: writeChars,
                                                  writeType: bluetoothManager.writeTypeCharacteristic)
            }
        }
    }
}
