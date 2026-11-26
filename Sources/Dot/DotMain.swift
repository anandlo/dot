import AppKit
import DotCore
import Foundation

// Dot is a menu bar application: it has no dock icon and never takes
// focus. `LSUIElement` in the bundle's Info.plist does the same thing for
// the installed app; setting the activation policy here covers a run from the
// build directory.

@main
@MainActor
enum DotMain {
    /// What the identity migration moved, so the log can say so once it has a
    /// file. It carries booleans only: no path and no secret.
    static var pendingMigrationReport: DotMigration.FileReport?

    static func main() {
        // A test trigger can open the microphone without the user asking. A
        // stale variable in a launcher must never be able to do that: the
        // binary refuses to start unless the launcher also passed the
        // explicit flag. This is checked before AppKit is even created, so
        // nothing can appear on screen.
        if DotMigration.environment("TEST_TRIGGER") != nil,
           !CommandLine.arguments.contains("--allow-test-trigger") {
            FileHandle.standardError.write(
                Data("Dot: refusing DOT_TEST_TRIGGER without --allow-test-trigger\n".utf8)
            )
            exit(2)
        }

        let application = NSApplication.shared

        // The listener stops at the first shutdown signal. The flock lease is
        // released only after `application.run()` has returned.
        var ownedCoordinator: SingleInstanceCoordinator?
        defer {
            ownedCoordinator?.beginShutdown()
            ownedCoordinator?.close()
        }

        // A single-instance lease belongs to the user-facing app only. Render
        // tools, menu dumps, XCTest hosts and trigger-enabled one-shots must
        // keep their current paths and never create a lease or a socket.
        if !SingleInstance.bypassesCoordinator() {
            do {
                let coordinator = try SingleInstanceCoordinator()
                switch try coordinator.acquireOrHandOff(
                    deadline: .after(milliseconds: SingleInstanceCoordinator.handoffDeadlineMilliseconds)
                ) {
                case .secondary:
                    // The running instance will reopen after its ready handler
                    // has run. This launch has no lease and no app state to unwind.
                    exit(0)
                case .primary:
                    SingleInstanceCoordinator.shared = coordinator
                    coordinator.startReopenLoop()
                    ownedCoordinator = coordinator
                }
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                exit(1)
            }
        }

        // The identity migration is the very first thing that runs. `DotConfig`
        // and `Log` compute their paths when they are first touched, and both
        // of those paths changed with the name, so the folders have to be in
        // their new place before either of them is asked for anything.
        let migration = DotMigration.runSynchronously()

        if migration.movedAnything {
            DotMain.pendingMigrationReport = migration
        }

        if CommandLine.arguments.contains(MenuDump.argument) {
            MenuDump.run()
            exit(0)
        }

        // The HUD is rendered to a file and the process exits. No window is
        // created, so a render never appears on the user's screen.
        if let directory = HUDPreview.requestedDirectory() {
            application.setActivationPolicy(.prohibited)
            do {
                try HUDPreview.renderAll(to: directory)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("HUD render failed: \(error)\n".utf8))
                exit(1)
            }
        }

        // The card is drawn as a film and the process exits: one deterministic
        // frame per tick of a fixed clock, so the recording needs no screen.
        if let directory = DemoRender.requestedDirectory() {
            application.setActivationPolicy(.prohibited)
            do {
                try DemoRender.renderAll(to: directory)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Demo render failed: \(error)\n".utf8))
                exit(1)
            }
        }

        // The About page's matrix motion is rendered to a directory and the
        // process exits. No window is created and nothing is ordered front.
        if let directory = UIPreview.requestedMotionDirectory() {
            application.setActivationPolicy(.prohibited)
            // A render bundle carries the app's own font directory, the same
            // way the packaged app does. Registering here keeps a strip in the
            // shipped face instead of a silent system-font fallback.
            if let resources = Bundle.main.resourceURL {
                DotType.registerFonts(at: resources.appendingPathComponent("Fonts"))
            }
            do {
                try UIPreview.renderAboutMotionStudy(to: directory)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("About motion render failed: \(error)\n".utf8))
                exit(1)
            }
        }

        // The light windows are rendered to a directory and the process exits.
        if let directory = UIPreview.requestedDirectory() {
            application.setActivationPolicy(.prohibited)
            do {
                try UIPreview.renderAll(to: directory)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("UI render failed: \(error)\n".utf8))
                exit(1)
            }
        }

        // The app icon and the menu bar glyph are rendered to a directory and
        // the process exits. `scripts/render-icon.sh` is the only caller.
        if let directory = IconRender.requestedDirectory() {
            application.setActivationPolicy(.prohibited)
            let mark = IconRender.requestedMark()
            do {
                try IconRender.renderAll(to: directory, mark: mark)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Icon render failed: \(error)\n".utf8))
                exit(1)
            }
        }

        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
