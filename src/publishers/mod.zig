const std = @import("std");

const github = @import("github.zig");
const aur = @import("aur.zig");
const homebrew = @import("homebrew.zig");

pub const GitHubClient = github.GitHubClient;
pub const ReleaseOptions = github.ReleaseOptions;
pub const ReleaseInfo = github.ReleaseInfo;
pub const AssetInfo = github.AssetInfo;
pub const ReleaseResult = github.ReleaseResult;
pub const GitHubError = github.GitHubError;
pub const ClientOptions = github.ClientOptions;
pub const publishRelease = github.publishRelease;
pub const AurPublishOptions = aur.AurPublishOptions;
pub const AurPublishResult = aur.AurPublishResult;
pub const AurError = aur.AurError;
pub const publishAurPackage = aur.publishAurPackage;
pub const HomebrewPublishOptions = homebrew.HomebrewPublishOptions;
pub const HomebrewPublishResult = homebrew.HomebrewPublishResult;
pub const HomebrewPublishError = homebrew.HomebrewPublishError;
pub const publishHomebrewFormula = homebrew.publishHomebrewFormula;
pub const ScoopPublishOptions = scoop.ScoopPublishOptions;
pub const ScoopPublishResult = scoop.ScoopPublishResult;
pub const ScoopPublishError = scoop.ScoopPublishError;
pub const publishScoopManifest = scoop.publishScoopManifest;
pub const WingetPublishOptions = winget.WingetPublishOptions;
pub const WingetPublishResult = winget.WingetPublishResult;
pub const WingetPublishError = winget.WingetPublishError;
pub const publishWingetManifest = winget.publishWingetManifest;

const scoop = @import("scoop.zig");
const winget = @import("winget.zig");

pub const GitHubErrorCode = enum {
    none,
    auth_failed,
    not_found,
    rate_limited,
    already_exists,
    server_error,
    network_error,
    parse_error,
    file_error,
    missing_token,
    timeout,
};

pub const GitHubErrorDetail = struct {
    code: GitHubErrorCode,
    message: []const u8,
};

test "module exports" {
    _ = GitHubClient;
    _ = ReleaseOptions;
    _ = ReleaseInfo;
    _ = AssetInfo;
    _ = ReleaseResult;
    _ = GitHubError;
    _ = ClientOptions;
    _ = publishRelease;
    _ = AurPublishOptions;
    _ = AurPublishResult;
    _ = AurError;
    _ = publishAurPackage;
    _ = HomebrewPublishOptions;
    _ = HomebrewPublishResult;
    _ = HomebrewPublishError;
    _ = publishHomebrewFormula;
    _ = ScoopPublishOptions;
    _ = ScoopPublishResult;
    _ = ScoopPublishError;
    _ = publishScoopManifest;
    _ = WingetPublishOptions;
    _ = WingetPublishResult;
    _ = WingetPublishError;
    _ = publishWingetManifest;
}
