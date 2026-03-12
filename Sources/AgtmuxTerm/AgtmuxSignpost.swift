import os

enum AgtmuxSignpost {
    static let ghosttyTick  = OSSignposter(subsystem: "local.agtmux.term", category: "GhosttyTick")
    static let surfaceDraw  = OSSignposter(subsystem: "local.agtmux.term", category: "SurfaceDraw")
    static let fetchAll     = OSSignposter(subsystem: "local.agtmux.term", category: "FetchAll")
    static let metadataSync = OSSignposter(subsystem: "local.agtmux.term", category: "MetadataSync")
    static let tmuxRunner   = OSSignposter(subsystem: "local.agtmux.term", category: "TmuxRunner")
    static let publish      = OSSignposter(subsystem: "local.agtmux.term", category: "Publish")
}
