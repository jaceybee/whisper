// Copyright 2023 Daniel C Brotsky.  All rights reserved.
//
// All material in this project and repository is licensed under the
// GNU Affero General Public License v3. See the LICENSE file for details.

import Combine
import CoreBluetooth

final class BluetoothFactory: NSObject, TransportFactory {
    typealias Publisher = BluetoothWhisperTransport
    typealias Subscriber = BluetoothListenTransport
    
    static let shared: BluetoothFactory = .init()
        
    var statusSubject: CurrentValueSubject<TransportStatus, Never> = .init(offStatus)
    
    var publisherUrl: TransportUrl = nil
    
    func publisher(_ publisherUrl: TransportUrl) -> Publisher {
        if publisherUrl != nil {
            logger.warning("Ignoring the publisher URL given to the Bluetooth whisper transport")
        }
        return Publisher()
    }
    
    func subscriber(_ publisherUrl: TransportUrl) -> Subscriber {
        if publisherUrl != nil {
            logger.warning("Ignoring the publisher URL given to the Bluetooth listen transport")
        }
        return Subscriber()
    }
    
    static let offStatus: TransportStatus = .off("Waiting for Bluetooth before continuing...")
    var advertisementSubject: PassthroughSubject<(CBPeripheral, [String: Any]), Never> = .init()
    var servicesSubject: PassthroughSubject<(CBPeripheral, [CBService]), Never> = .init()
    var characteristicsSubject: PassthroughSubject<(CBPeripheral, CBService), Never> = .init()
    var centralSubscribedSubject: PassthroughSubject<(CBCentral, CBCharacteristic), Never> = .init()
    var centralUnsubscribedSubject: PassthroughSubject<(CBCentral, CBCharacteristic), Never> = .init()
    var readRequestSubject: PassthroughSubject<CBATTRequest, Never> = .init()
    var writeRequestSubject: PassthroughSubject<[CBATTRequest], Never> = .init()
    var writeResultSubject: PassthroughSubject<(CBPeripheral, CBCharacteristic, Error?), Never> = .init()
    var notifyResultSubject: PassthroughSubject<(CBPeripheral, CBCharacteristic, Error?), Never> = .init()
    var readyToUpdateSubject: PassthroughSubject<(), Never> = .init()
    var receivedValueSubject: PassthroughSubject<(CBPeripheral, CBCharacteristic, Error?), Never> = .init()
    var disconnectedSubject: PassthroughSubject<CBPeripheral, Never> = .init()

    private var centralManager: CBCentralManager!
    private var peripheralManager: CBPeripheralManager!
    
    private var central_state: CBManagerState = .unknown
    private var peripheral_state: CBManagerState = .unknown

    override init() {
        super.init()
        centralManager = .init(delegate: self, queue: .main)
        peripheralManager = .init(delegate: self, queue: .main)
    }
    
    func connectedPeripherals(forServices: [CBUUID]) -> [CBPeripheral] {
        return centralManager.retrieveConnectedPeripherals(withServices: forServices)
    }
    
    func scan(forServices: [CBUUID], allow_repeats: Bool = false) {
        guard !forServices.isEmpty else {
            fatalError("Can't scan for no services")
        }
        centralManager.scanForPeripherals(
            withServices: forServices,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: allow_repeats as NSNumber]
        )
    }
    
    func stopScan() {
        logger.log("Stop scanning for whisperers")
        centralManager.stopScan()
    }
    
    func publish(service: CBMutableService) {
        peripheralManager.add(service)
    }
    
    func unpublish(service: CBMutableService) {
        peripheralManager.remove(service)
    }
    
    func unpublishAll() {
        peripheralManager.removeAllServices()
    }
    
    func advertise(services: [CBUUID], localName: String = BluetoothData.deviceId) {
        guard !services.isEmpty else {
            fatalError("Can't advertise no services")
        }
        peripheralManager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: services,
            CBAdvertisementDataLocalNameKey: localName,
        ])
    }
    
    func stopAdvertising() {
        peripheralManager.stopAdvertising()
    }
    
    func connect(_ peripheral: CBPeripheral) {
        peripheral.delegate = self
        centralManager.connect(peripheral)
    }
    
    func disconnect(_ peripheral: CBPeripheral) {
        centralManager.cancelPeripheralConnection(peripheral)
    }
    
    func respondToReadRequest(request: CBATTRequest, withCode: CBATTError.Code) {
        peripheralManager.respond(to: request, withResult: withCode)
    }
    
    func respondToWriteRequest(request: CBATTRequest, withCode: CBATTError.Code) {
        peripheralManager.respond(to: request, withResult: withCode)
    }
    
    func updateValue(value: Data, characteristic: CBMutableCharacteristic) -> Bool {
        return peripheralManager.updateValue(value, for: characteristic, onSubscribedCentrals: nil)
    }
    
    func updateValue(value: Data, characteristic: CBMutableCharacteristic, central: CBCentral) -> Bool {
        return peripheralManager.updateValue(value, for: characteristic, onSubscribedCentrals: [central])
    }
    
    private func compositeStatus() -> TransportStatus {
        if central_state == .poweredOn && peripheral_state == .poweredOn {
            return .on
        } else if central_state == .unauthorized || peripheral_state == .unauthorized {
            return .disabled("Enable Bluetooth to continue...")
        } else {
            return BluetoothFactory.offStatus
        }
    }
}

extension BluetoothFactory: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        central_state = central.state
        statusSubject.send(compositeStatus())
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        advertisementSubject.send((peripheral, advertisementData))
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        logger.log("Got connect from \(peripheral)")
        peripheral.discoverServices([BluetoothData.whisperServiceUuid])
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        disconnectedSubject.send(peripheral)
    }
}

extension BluetoothFactory: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        peripheral_state = peripheral.state
        statusSubject.send(compositeStatus())
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let err = error {
            logger.error("Add \(service) failed with \(err)")
            fatalError("Couldn't add the service \(service) - please report a bug!")
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        centralSubscribedSubject.send((central, characteristic))
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        centralUnsubscribedSubject.send((central, characteristic))
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        readRequestSubject.send(request)
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        writeRequestSubject.send(requests)
    }
    
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        readyToUpdateSubject.send(())
    }
}

extension BluetoothFactory: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let err = error {
            logger.error("Error discovering services for \(peripheral): \(err)")
            return
        }
        servicesSubject.send((peripheral, peripheral.services ?? []))
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let err = error {
            logger.error("Error discovering characteristics for \(service) on \(peripheral): \(err)")
            return
        }
        characteristicsSubject.send((peripheral, service))
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        writeResultSubject.send((peripheral, characteristic, error))
    }
        
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        receivedValueSubject.send((peripheral, characteristic, error))
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        notifyResultSubject.send((peripheral, characteristic, error))
    }
    
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        logger.log("Lost services \(invalidatedServices) from \(peripheral)")
        if invalidatedServices.first(where: { $0.uuid == BluetoothData.whisperServiceUuid }) != nil {
            disconnectedSubject.send(peripheral)
        }
    }
}
