import Testing
@testable import BirthCore

@Suite("launchctl output parsing")
struct LaunchctlParsingTests {
    @Test func parsesPrintDisabledModernFormat() {
        let output = """

        	disabled services = {
        		"com.example.enabled-thing" => enabled
        		"com.example.disabled-thing" => disabled
        		"com.example.spaced name" => disabled
        	}

        """
        let overrides = LaunchctlClient.parsePrintDisabled(output)
        #expect(overrides["com.example.enabled-thing"] == false)
        #expect(overrides["com.example.disabled-thing"] == true)
        #expect(overrides["com.example.spaced name"] == true)
        #expect(overrides.count == 3)
    }

    @Test func parsesPrintDisabledLegacyBooleanFormat() {
        let output = """
        	disabled services = {
        		"com.legacy.a" => true
        		"com.legacy.b" => false
        	}
        """
        let overrides = LaunchctlClient.parsePrintDisabled(output)
        // In the legacy format the value is the *disabled* flag.
        #expect(overrides["com.legacy.a"] == true)
        #expect(overrides["com.legacy.b"] == false)
    }

    @Test func parsesListOutput() {
        let output = """
        PID	Status	Label
        -	0	com.example.idle
        512	0	com.example.running
        -	78	com.example.crashed
        """
        let jobs = LaunchctlClient.parseList(output)
        #expect(jobs.count == 3)
        #expect(jobs["com.example.idle"] == JobRuntime(pid: nil))
        #expect(jobs["com.example.running"] == JobRuntime(pid: 512))
        #expect(jobs["com.example.crashed"] == JobRuntime(pid: nil))
    }

    @Test func parsesPrintServicesBlock() {
        let output = """
        system = {
        	type = system
        	service stats = {
        		unrelated = 1
        	}
        	services = {
        		       0      - 	com.example.daemon.idle
        		     766      - 	com.example.daemon.running
        		       0      1 	com.example.daemon.failed
        	}
        	other = {
        		       9      - 	com.example.should-not-appear
        	}
        }
        """
        let jobs = LaunchctlClient.parsePrintServices(output)
        #expect(jobs.count == 3)
        #expect(jobs["com.example.daemon.idle"] == JobRuntime(pid: nil))
        #expect(jobs["com.example.daemon.running"] == JobRuntime(pid: 766))
        #expect(jobs["com.example.should-not-appear"] == nil)
    }

    @Test func shellQuoteEscapesSingleQuotes() {
        #expect(shellQuote("plain") == "'plain'")
        #expect(shellQuote("it's") == "'it'\\''s'")
        #expect(shellQuote("闪电说 path") == "'闪电说 path'")
    }
}

@Suite("Privileged fragment outcomes")
struct PrivilegedOutcomeTests {
    @Test func parsesMarkers() {
        #expect(LaunchctlClient.parsePrivilegedOutcome("BIRTH_OK\n") == .ok)
        #expect(LaunchctlClient.parsePrivilegedOutcome("BIRTH_PERSIST_FAILED") == .persistFailed)
        #expect(LaunchctlClient.parsePrivilegedOutcome("noise\nBIRTH_STILL_LOADED\n") == .stillLoaded)
        // Unknown output defaults to ok — the exit status already gated hard failures.
        #expect(LaunchctlClient.parsePrivilegedOutcome("") == .ok)
    }

    @Test func disableFragmentCarriesMarkerProtocol() {
        let fragment = LaunchctlClient().shellCommandToDisableDaemon(label: "com.test.daemon")
        #expect(fragment.contains("BIRTH_PERSIST_FAILED"))
        #expect(fragment.contains("BIRTH_STILL_LOADED"))
        #expect(fragment.contains("BIRTH_OK"))
        #expect(fragment.contains("launchctl print"))
    }
}
