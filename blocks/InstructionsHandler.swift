//
//  InstructionsHandler.swift
//  blocks
//

import Foundation
import Alamofire
import SwiftyJSON

struct Cookie: Codable {
    let name: String
    let value: String
    let domain: String
    let secure: Bool
    let httpOnly: Bool
    let path: String
}

struct Request: Codable {
    let url: String
    let method: String
    let body: [String: String]?
    let headers: [String: String]
    let cookies: [Cookie]?
    let etag: String
}

struct Response: Codable {
    let type: String
    let headers: [String: String]
    let response: JSON
}

struct Instruction: Codable {
    let request: Request
}

typealias ActHandler = (_ value: String) -> ()

/**
 The InstructionsHandler struct handles INSTRUCTIONS messages coming from the WebView.
 
 Each instruction has an etag, to allow us to differnate between them and only execute each instruction once.
 After we have executed an instruction we respond back to the WebView via postMessage with the reply from the
 upstream server.
 
 This specific class uses Alamofire and SwiftyJSON to simplify the code somewhat.
 */
struct InstructionsHandler {
    var handledInstructions: [String: Bool] = [:]
    var instructions: [Instruction] = []

    mutating func addInstruction(encoded: [String: Any]) -> Instruction? {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: encoded) else {
            return nil
        }
        let decoder = JSONDecoder()
        guard let instruction = try? decoder.decode(Instruction.self, from: jsonData) else {
            return nil
        }
        let etag = instruction.request.etag
        if handledInstructions.index(forKey: etag) == nil {
            self.instructions.append(instruction)
            handledInstructions[etag] = true
            return instruction
        }
        return nil
    }

    func setCookies(cookies: [Cookie]) {
        cookies.forEach { cookie in
            let properties: [HTTPCookiePropertyKey: Any] = [
                .name: cookie.name,
                .value: cookie.value,
                .domain: cookie.domain,
                .path: cookie.path,
                .secure: cookie.secure,
            ]
            if let httpCookie = HTTPCookie(properties: properties) {
                HTTPCookieStorage.shared.setCookie(httpCookie)
            }
        }
    }

    func execute(handler: @escaping ActHandler) {
        guard let request = instructions.last?.request else { return }
        let headers = HTTPHeaders(
            request.headers.map({ (key: String, value: String) in
                HTTPHeader(name: key, value: value)
            })
        )
        if let cookies = request.cookies {
            setCookies(cookies: cookies)
        }
        let method: HTTPMethod = (request.method == "POST") ? .post : .get
        AF.request(
            request.url,
            method: method,
            parameters: request.body,
            encoder: JSONParameterEncoder.sortedKeys,
            headers: headers
        )
        .responseJSON { response in
            if let statusCode = response.response?.statusCode {
                switch statusCode {
                case 200:
                    let json = JSON(response.data)
                    let responseHeaders = response.response?.headers.reduce(into: [String: String]()) {
                        $0[$1.name] = $1.value
                    }
                    let responseToInsurely = Response(type: "RESPONSE_OBJECT", headers: responseHeaders!, response: json)
                    let encoder = JSONEncoder()
                    if let jsonEncoded = try? encoder.encode(responseToInsurely) {
                        handler(String(data: jsonEncoded, encoding: .utf8)!)
                    }
                case 400:
                    print("Error in authentication")
                case 401:
                    print("Error authentication object was not found")
                default:
                    print("default")
                }
            }
        }
    }
}
