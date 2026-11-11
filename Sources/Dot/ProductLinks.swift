import Foundation

/// Where Dot lives, and what it calls itself.
///
/// Every URL and display name the app publishes is declared here and read from
/// here: the About window and the About page in Settings show the same list, and
/// the update check reads the same repository. Two copies of a URL is how one of
/// them ends up pointing somewhere stale.
///
/// `index.html` and `README.md` are separate marketing surfaces and carry the
/// same values by hand. They are not generated from this file, so a change to a
/// destination means changing it in both places.
enum ProductLinks {
    /// The GitHub repository, as owner and name.
    static let repository = "anandlo/dot"

    /// The source repository.
    static let github = URL(string: "https://github.com/\(repository)")!

    /// The marketing site, which is also where a failed update check sends the
    /// person.
    static let website = URL(string: "https://dot.anandlo.com")!

    /// Where the project can be supported.
    static let support = URL(string: "https://buymeacoffee.com/anandlo")!

    /// The form a bug report starts in.
    static let newIssue = URL(string: "https://github.com/\(repository)/issues/new")!

    /// The licence the project ships, as the repository renders it.
    static let licence = URL(string: "https://github.com/\(repository)/blob/main/LICENSE")!

    /// The licence's name, which is the shortest honest way to say it.
    static let licenceName = "MIT"

    /// Who made the app, as the About window credits them.
    static let author = "Anand Lo"

    /// The copyright line, kept in step with `LICENSE`.
    static let copyright = "© 2026 Anand Lo"

    /// The GitHub Releases endpoint the update check reads.
    ///
    /// It leaves prereleases out, so a release that is one is not this URL's
    /// answer; the update check asks ``releaseList`` next.
    static let latestRelease = URL(
        string: "https://api.github.com/repos/\(repository)/releases/latest"
    )!

    /// The Releases list endpoint, newest first, prereleases included.
    ///
    /// While every Dot release is a prerelease, this is the endpoint that can
    /// name the newest build. The request path matches the one
    /// `scripts/install-remote.sh` falls back to.
    static let releaseList = URL(
        string: "https://api.github.com/repos/\(repository)/releases?per_page=1"
    )!

    /// The line the About window shows under the name.
    static let tagline = "Write as fast as you can think."

    /// GitHub shown without its scheme, which is how people write it.
    static var displayGitHub: String {
        github.absoluteString.replacingOccurrences(of: "https://", with: "")
    }

    /// The support page shown without its scheme.
    static var displaySupport: String {
        support.absoluteString.replacingOccurrences(of: "https://", with: "")
    }

    /// The website's host, which is the shortest honest name for it.
    static var displayWebsite: String? {
        website.host
    }

    /// The issue tracker, named as a place rather than as a form.
    static let displayIssues = "GitHub Issues"

    /// The licence viewed in the repository.
    static var displayLicence: String {
        licence.absoluteString.replacingOccurrences(of: "https://", with: "")
    }
}
