import Foundation

/// Typed command parameters for the LingBot model — action-controlled
/// world generation, the closest Reactor model to a real-time video
/// game. Mirrors the wire schema at
/// `https://docs.reactor.inc/model-api-reference/lingbot/schema`.
///
/// Specialty: **persistent action inputs**. You don't send one frame
/// per movement — you set `movement`, `look_horizontal`,
/// `look_vertical` as sticky state that the model honors on every
/// subsequent chunk until you change it. Treat it like a virtual
/// joystick, not a keyboard event stream.
public enum LingBot {

    /// Movement direction. Persistent until changed.
    public enum Movement: String, Encodable, Sendable, Equatable, CaseIterable {
        case idle
        case forward
        case back
        case strafeLeft = "strafe_left"
        case strafeRight = "strafe_right"
    }

    /// Horizontal look (yaw) direction. Persistent until changed.
    public enum LookHorizontal: String, Encodable, Sendable, Equatable, CaseIterable {
        case idle, left, right
    }

    /// Vertical look (pitch) direction. Persistent until changed.
    public enum LookVertical: String, Encodable, Sendable, Equatable, CaseIterable {
        case idle, up, down
    }

    /// Parameters for `set_prompt`. Max 1000 characters; server-side
    /// truncation surfaces as `command_error`.
    public struct SetPromptParams: Encodable, Sendable, Equatable {
        public let prompt: String
        public init(prompt: String) { self.prompt = prompt }
    }

    /// Parameters for `set_image`. Required before `start` — LingBot
    /// won't generate without a seed image.
    public struct SetImageParams: Encodable, Sendable, Equatable {
        public let image: FileRef
        public init(image: FileRef) { self.image = image }
    }

    /// Parameters for `set_movement`.
    public struct SetMovementParams: Encodable, Sendable, Equatable {
        public let movement: Movement
        public init(_ movement: Movement) { self.movement = movement }
    }

    /// Parameters for `set_look_horizontal`.
    public struct SetLookHorizontalParams: Encodable, Sendable, Equatable {
        // swiftlint:disable:next identifier_name
        public let look_horizontal: LookHorizontal
        public init(_ look: LookHorizontal) { self.look_horizontal = look }
    }

    /// Parameters for `set_look_vertical`.
    public struct SetLookVerticalParams: Encodable, Sendable, Equatable {
        // swiftlint:disable:next identifier_name
        public let look_vertical: LookVertical
        public init(_ look: LookVertical) { self.look_vertical = look }
    }

    /// Parameters for `set_rotation_speed_deg`. Range `0.0...30.0`,
    /// default `5.0`. Applies to both look axes.
    public struct SetRotationSpeedParams: Encodable, Sendable, Equatable {
        // swiftlint:disable:next identifier_name
        public let rotation_speed_deg: Double
        public init(degreesPerChunk: Double) { self.rotation_speed_deg = degreesPerChunk }
    }

    /// Parameters for `set_seed`. Read once on `start`; changes after
    /// that require `reset` + new `start`. Default server-side: 42.
    public struct SetSeedParams: Encodable, Sendable, Equatable {
        public let seed: Int
        public init(seed: Int) { self.seed = seed }
    }
}
