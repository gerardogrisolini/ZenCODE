import Foundation

func write(_ string: String, stderr: Bool = false) {
    let data = Data(string.utf8)
    if stderr {
        FileHandle.standardError.write(data)
    } else {
        FileHandle.standardOutput.write(data)
    }
}

func writeLine(_ string: String, stderr: Bool = false) {
    write(string + "\n", stderr: stderr)
}
