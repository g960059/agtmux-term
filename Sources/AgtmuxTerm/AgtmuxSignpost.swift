import os

enum AgtmuxSignpost {
    static let ghosttyTick  = OSSignposter(subsystem: "local.agtmux.term", category: "GhosttyTick")
    static let surfaceDraw  = OSSignposter(subsystem: "local.agtmux.term", category: "SurfaceDraw")
    static let scrollLatency = OSSignposter(subsystem: "local.agtmux.term", category: "ScrollLatency")
    static let fetchAll     = OSSignposter(subsystem: "local.agtmux.term", category: "FetchAll")
    static let localInventory = OSSignposter(subsystem: "local.agtmux.term", category: "LocalInventory")
    static let remoteInventory = OSSignposter(subsystem: "local.agtmux.term", category: "RemoteInventory")
    static let metadataSync = OSSignposter(subsystem: "local.agtmux.term", category: "MetadataSync")
    static let navigationSync = OSSignposter(subsystem: "local.agtmux.term", category: "NavigationSync")
    static let remoteSSH    = OSSignposter(subsystem: "local.agtmux.term", category: "RemoteSSH")
    static let tmuxRunner   = OSSignposter(subsystem: "local.agtmux.term", category: "TmuxRunner")
    static let publish      = OSSignposter(subsystem: "local.agtmux.term", category: "Publish")
    static let publishAssemble = OSSignposter(subsystem: "local.agtmux.term", category: "PublishAssemble")
    static let ghosttyBridge = OSSignposter(subsystem: "local.agtmux.term", category: "GhosttyBridge")
}
