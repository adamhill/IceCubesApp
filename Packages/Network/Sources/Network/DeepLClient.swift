import Alamofire
import Foundation
import Models

public struct DeepLClient: Sendable {
  public enum DeepLError: Error {
    case notFound
  }

  private var deeplUserAPIKey: String?
  private var deeplUserAPIFree: Bool
  private var endpoint: String {
    "https://api\(deeplUserAPIFree && (deeplUserAPIKey != nil) ? "-free" : "").deepl.com/v2/translate"
  }

  private var authorizationHeaderValue: String {
    "DeepL-Auth-Key \(deeplUserAPIKey ?? "")"
  }

  public struct Response: Decodable {
    public struct Translation: Decodable {
      public let detectedSourceLanguage: String
      public let text: String
    }

    public let translations: [Translation]
  }

  private var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }

  public init(userAPIKey: String?, userAPIFree: Bool) {
    deeplUserAPIKey = userAPIKey
    deeplUserAPIFree = userAPIFree
  }

  public func request(target: String, text: String) async throws -> Translation {
    let parameters: [String: String] = [
      "text": text,
      "target_lang": target.uppercased()
    ]
    
    let headers: HTTPHeaders = [
      "Authorization": authorizationHeaderValue,
      "Content-Type": "application/x-www-form-urlencoded"
    ]
    
    return try await withCheckedThrowingContinuation { continuation in
      AF.request(
        endpoint,
        method: .post,
        parameters: parameters,
        encoder: URLEncodedFormParameterEncoder.default,
        headers: headers
      ).responseData { response in
        switch response.result {
        case .success(let data):
          do {
            let decodedResponse = try self.decoder.decode(Response.self, from: data)
            if let translation = decodedResponse.translations.first {
              let result = Translation(
                content: translation.text.removingPercentEncoding ?? "",
                detectedSourceLanguage: translation.detectedSourceLanguage,
                provider: "DeepL.com")
              continuation.resume(returning: result)
            } else {
              continuation.resume(throwing: DeepLError.notFound)
            }
          } catch {
            continuation.resume(throwing: error)
          }
        case .failure(let error):
          continuation.resume(throwing: error)
        }
      }
    }
  }
}
