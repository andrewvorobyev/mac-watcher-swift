import Foundation

struct ObserveMain {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 2 else {
            log("Usage: observe <pid>")
            exit(EXIT_FAILURE)
        }

        let pidArgument = arguments[1]
        guard let pidValue = Int32(pidArgument), pidValue > 0 else {
            log("Invalid process identifier: \(pidArgument)")
            exit(EXIT_FAILURE)
        }

        log("Observing process with pid: \(pidValue)")
    }

    private static func log(_ message: String) {
        print(message)
    }
}

ObserveMain.main()
