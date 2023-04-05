// Copyright 2023 Daniel C Brotsky.  All rights reserved.
//
// All material in this project and repository is licensed under the
// GNU Affero General Public License v3. See the LICENSE file for details.

import Combine
import CoreBluetooth

let connectingLiveText = "This is where the line being typed by the whisperer will appear in real time... "
let connectingPastText = """
This is where lines will move after the whisperer hits return.
The most recent line will be on the bottom.
"""
let unknownWhispererName = "(not yet known)"

final class ListenViewModel: ObservableObject {
    @Published var statusText: String = ""
    @Published var liveText: String = ""
    var pastText: PastTextViewModel = .init()
    
    private var manager = BluetoothManager.shared
    private var cancellables: Set<AnyCancellable> = []
    private var whisperer: CBPeripheral?
    private var whispererName: String = unknownWhispererName
    private var nameCharacteristic: CBCharacteristic?
    private var textCharacteristic: CBCharacteristic?
    private var disconnectCharacteristic: CBCharacteristic?
    private var scanInProgress = false
    private var wasInBackground = false
    private var resetInProgress = false

    init() {
        manager.peripheralSubject
            .sink{ [weak self] in self?.foundWhisperer($0) }
            .store(in: &cancellables)
        manager.servicesSubject
            .sink{ [weak self] in self?.connectedWhisperer($0) }
            .store(in: &cancellables)
        manager.characteristicsSubject
            .sink{ [weak self] in self?.whispererReady($0) }
            .store(in: &cancellables)
        manager.receivedValueSubject
            .sink{ [weak self] in self?.readValue($0) }
            .store(in: &cancellables)
        manager.disconnectedSubject
            .sink{ [weak self] in self?.wasDisconnected($0) }
            .store(in: &cancellables)
    }
    
    deinit {
        cancellables.cancel()
    }
    
    func start() {
        findWhisperer()
    }
    
    func stop() {
        disconnect()
    }
    
    func wentToBackground() {
        wasInBackground = true
    }
    
    func wentToForeground() {
        if wasInBackground {
            wasInBackground = false
            readAllText()
        }
    }
    
    func readAllText() {
        guard whisperer != nil && textCharacteristic != nil else {
            return
        }
        guard !resetInProgress else {
            print("Got reset during reset, ignoring it")
            return
        }
        resetInProgress = true
        whisperer!.readValue(for: textCharacteristic!)
    }
    
    private func findWhisperer() {
        guard whisperer == nil else {
            print("Tried to find a whisperer when we have one, ignoring request")
            return
        }
        statusText = "Looking for a whisperer to listen to…"
        liveText = connectingLiveText
        pastText.setFromText(connectingPastText)
        if !scanInProgress {
            scanInProgress = true
            print("Advertising listener and scanning for whisperer...")
            manager.scan(forServices: [WhisperData.whisperServiceUuid])
            manager.advertise(services: [WhisperData.listenServiceUuid])
        }
    }
    
    private func stopFindWhisperer(connectComplete: Bool) {
        if scanInProgress {
            scanInProgress = false
            print("Stop advertising listener and scanning for whisperer")
            manager.stopScan()
            manager.stopAdvertising()
        }
        if connectComplete {
            statusText = "Listening to \(whispererName)"
            liveText = ""
            pastText.clearLines()
        }
    }
    
    private func foundWhisperer(_ pair: (CBPeripheral, [String: Any])) {
        stopFindWhisperer(connectComplete: false)
        guard whisperer == nil else {
            print("Already have a whisperer, won't connect to \(pair.0) with ad \(pair.1)")
            return
        }
        if let uuids = pair.1[CBAdvertisementDataServiceUUIDsKey] as? Array<CBUUID> {
            if uuids.contains(WhisperData.whisperServiceUuid) {
                print("Connecting to whisperer \(pair.0) with ad \(pair.1)")
                whisperer = pair.0
                manager.connect(whisperer!)
            }
        }
    }

    private func connectedWhisperer(_ pair: (CBPeripheral, [CBService])) {
        guard pair.0 == whisperer else {
            if let requested = whisperer {
                fatalError("Connected to whisperer \(pair.0) but requested connection to \(requested)")
            } else {
                fatalError("Connected to whisperer \(pair.0) but didn't request a connection")
            }
        }
        if let whisperSvc = pair.1.first(where: {svc in svc.uuid == WhisperData.whisperServiceUuid}) {
            print("Connected to whisperer \(whisperer!) with service \(pair.1), readying...")
            whisperer!.discoverCharacteristics(
                [
                    WhisperData.whisperNameUuid,
                    WhisperData.whisperTextUuid,
                    WhisperData.whisperDisconnectUuid,
                ],
                for: whisperSvc
            )
        } else {
            fatalError("Connected to advertised whisperer \(whisperer!) but it has no whisper service")
        }
    }
    
    private func whispererReady(_ service: CBService) {
        guard service.characteristics != nil else {
            fatalError("Readied whisper service with no characteristics: report a bug!")
        }
        print("Readying whisperer \(whisperer!)...")
        let allCs = service.characteristics!
        if let nameC = allCs.first(where: { $0.uuid == WhisperData.whisperNameUuid }) {
            nameCharacteristic = nameC
            whisperer?.readValue(for: nameCharacteristic!)
        } else {
            fatalError("Whisper service has no name characteristic: report a bug!")
        }
        if let liveTextC = allCs.first(where: { $0.uuid == WhisperData.whisperTextUuid }) {
            textCharacteristic = liveTextC
            whisperer!.setNotifyValue(true, for: textCharacteristic!)
        } else {
            fatalError("Whisper service has no live text characteristic: report a bug!")
        }
        if let disconnectC = allCs.first(where: { $0.uuid == WhisperData.whisperDisconnectUuid }) {
            disconnectCharacteristic = disconnectC
            whisperer!.setNotifyValue(true, for: disconnectC)
        } else {
            fatalError("Whisper service has no disconnect characteristic: report a bug!")
        }
        stopFindWhisperer(connectComplete: true)
        readAllText()
    }
    
    private func readValue(_ pair: (CBPeripheral, CBCharacteristic)) {
        guard pair.0 == whisperer else {
            fatalError("Received a read value from unexpected peripheral \(pair.0)")
        }
        let characteristic = pair.1
        if characteristic.uuid == disconnectCharacteristic?.uuid {
            print("Received disconnect from whisperer")
            disconnect()
        } else if characteristic.uuid == nameCharacteristic?.uuid {
            print("Received name value from whisperer")
            if let nameData = characteristic.value {
                if nameData.isEmpty {
                    whispererName = "(anonymous)"
                } else {
                    whispererName = String(decoding: nameData, as: UTF8.self)
                }
                statusText = "Listening to \(whispererName)"
            }
        } else if characteristic.uuid == textCharacteristic?.uuid {
            if let textData = characteristic.value,
               let chunk = TextProtocol.ProtocolChunk.fromData(textData) {
                if resetInProgress {
                    if chunk.isFirstRead() {
                        print("Received acknowledgement of read from whisperer")
                    } else if chunk.isDiff() {
                        print("Ignoring diff chunk because a read is in progress")
                    } else if chunk.isCompleteLine() {
                        print("Got past line \(pastText.pastText.count) in read")
                        pastText.addLine(chunk.text)
                    } else if chunk.isLastRead() {
                        print("Got live text in read")
                        liveText = chunk.text
                        resetInProgress = false
                    }
                } else {
                    if !chunk.isDiff() {
                        print("Ignoring non-diff chunk because no read in progress")
                    } else if chunk.offset == 0 {
                        print("Got diff: replacement of live text")
                        liveText = chunk.text
                    } else if chunk.isCompleteLine() {
                        print("Got diff: move live text to past text")
                        pastText.addLine(liveText)
                        liveText = ""
                    } else if chunk.offset > liveText.count {
                        // we must have missed a packet, read the full state to reset
                        print("Resetting after missed packet...")
                        readAllText()
                    } else {
                        print("Got diff: update to live text")
                        liveText = TextProtocol.applyDiff(old: liveText, chunk: chunk)
                    }
                }
            }
        } else {
            print("Got a received value notification for an unexpected characteristic: \(characteristic)")
        }
    }
    
    private func wasDisconnected(_ peripheral: CBPeripheral) {
        guard peripheral == whisperer else {
            print("Received disconnect from \(peripheral) while connected to \(String(describing: whisperer))")
            return
        }
        print("Whisperer disconnected")
        manager.disconnect(whisperer!)
        disconnectCharacteristic = nil
        nameCharacteristic = nil
        pastText.setFromText(connectingPastText)
        textCharacteristic = nil
        liveText = connectingLiveText
        whispererName = unknownWhispererName
        whisperer = nil
        findWhisperer()
    }
    
    private func disconnect() {
        stopFindWhisperer(connectComplete: true)
        if let liveTextC = textCharacteristic {
            whisperer!.setNotifyValue(false, for: liveTextC)
            textCharacteristic = nil
            liveText = connectingLiveText
        }
        if let disconnectC = disconnectCharacteristic {
            whisperer!.setNotifyValue(false, for: disconnectC)
            disconnectCharacteristic = nil
        }
        if let whisperP = whisperer {
            manager.disconnect(whisperP)
            whisperer = nil
            whispererName = unknownWhispererName
            nameCharacteristic = nil
            pastText.setFromText(connectingPastText)
        }
        statusText = "Stopped listening"
    }
}
