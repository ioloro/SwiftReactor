import Foundation
import Testing
@testable import SwiftReactor

/// Pins the wire-name mapping for every `ReactorModel` case. The
/// names are part of the SDK's contract with the Reactor
/// coordinator — drifting them silently routes sessions to the
/// wrong GPU pool (or, more likely, surfaces as `command_error`).
@Suite("ReactorModel wire-name mapping")
struct ReactorModelTests {

    @Test("longLiveV2 maps to `longlive-v2`")
    func longLiveWireName() {
        #expect(ReactorModel.longLiveV2.wireName == "longlive-v2")
    }

    @Test("helios maps to `helios`")
    func heliosWireName() {
        #expect(ReactorModel.helios.wireName == "helios")
    }

    @Test("lingbot maps to `lingbot`")
    func lingbotWireName() {
        #expect(ReactorModel.lingbot.wireName == "lingbot")
    }

    @Test("sanaStreaming maps to `sana-streaming`")
    func sanaStreamingWireName() {
        #expect(ReactorModel.sanaStreaming.wireName == "sana-streaming")
    }

    @Test(".custom passes through its associated string verbatim")
    func customWireName() {
        #expect(ReactorModel.custom("future-model-v9").wireName == "future-model-v9")
        #expect(ReactorModel.custom("").wireName == "")
    }

    @Test("Reactor(model:) routes to the same wireName")
    @MainActor func reactorInitHonorsEnum() {
        #expect(Reactor(model: .longLiveV2).configuration.modelName == "longlive-v2")
        #expect(Reactor(model: .helios).configuration.modelName == "helios")
        #expect(Reactor(model: .lingbot).configuration.modelName == "lingbot")
        #expect(Reactor(model: .sanaStreaming).configuration.modelName == "sana-streaming")
        #expect(Reactor(model: .custom("xyz")).configuration.modelName == "xyz")
    }
}
