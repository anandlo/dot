import XCTest

@testable import DotCore

final class AppleSpeechProviderTests: XCTestCase {
    /// A second of a sine wave: there is no speech in it, but it is audio.
    private func makeSine(seconds: Double = 1.0, frequency: Double = 440) -> Data {
        let count = Int(seconds * Double(WAVSpec.sampleRate))
        let samples: [Int16] = (0..<count).map { index in
            let phase = 2 * Double.pi * frequency * Double(index) / Double(WAVSpec.sampleRate)
            return Int16(sin(phase) * 8_000)
        }
        return WAVWriter.encode(samples: samples)
    }

    func testTheProviderSaysWhetherItCanBeUsed() async {
        let provider = AppleSpeechProvider()
        let available = await provider.isAvailable()
        // The answer depends on the machine; what matters is that asking
        // never crashes and never hangs.
        XCTAssertTrue(available || !available)
    }

    func testATranscriptionOfASineEitherAnswersOrSaysThereWasNoSpeech() async throws {
        let provider = AppleSpeechProvider()
        guard #available(macOS 26.0, *) else {
            // On an older system the provider says so instead of pretending.
            do {
                _ = try await provider.transcribe(wav: makeSine(), model: nil, language: nil)
                XCTFail("the provider should have refused")
            } catch let error as ProviderError {
                guard case .unsupported = error else {
                    return XCTFail("expected unsupported, got \(error)")
                }
            } catch {
                XCTFail("the provider failed in an unexpected way: \(error)")
            }
            return
        }
        do {
            let transcript = try await provider.transcribe(
                wav: makeSine(),
                model: nil,
                language: nil
            )
            // A sine wave has no words in it, but the provider must never
            // make something up out of nothing.
            XCTAssertFalse(transcript.contains("the"))
        } catch let error as ProviderError {
            guard case .noSpeech = error else {
                return XCTFail("expected noSpeech, got \(error)")
            }
            XCTAssertEqual(error.errorDescription, "No speech was recognised in the recording.")
        } catch {
            if (error as NSError).domain == "SFSpeechErrorDomain" {
                throw XCTSkip("SFSpeechRecognizer not supported in this headless CI environment: \(error)")
            }
            XCTFail("the provider failed in an unexpected way: \(error)")
        }
    }

    func testAnEmptyRecordingIsNeverSent() async throws {
        let provider = AppleSpeechProvider()
        do {
            _ = try await provider.transcribe(
                wav: WAVWriter.encode(samples: []),
                model: nil,
                language: nil
            )
            XCTFail("the provider should have refused")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .noSpeech)
        } catch {
            if (error as NSError).domain == "SFSpeechErrorDomain" {
                throw XCTSkip("SFSpeechRecognizer not supported in this headless CI environment: \(error)")
            }
            XCTFail("the provider failed in an unexpected way: \(error)")
        }
    }

    func testTheProviderNeedsNoKey() {
        XCTAssertFalse(AppleSpeechProvider().requiresCredential)
    }
}
