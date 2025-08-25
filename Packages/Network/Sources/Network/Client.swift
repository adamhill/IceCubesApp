import Alamofire
import Combine
import Foundation
import Models
import OSLog
import Observation
import SwiftUI
import os

@Observable public final class Client: Equatable, Identifiable, Hashable, @unchecked Sendable {
  public static func == (lhs: Client, rhs: Client) -> Bool {
    let lhsToken = lhs.critical.withLock { $0.oauthToken }
    let rhsToken = rhs.critical.withLock { $0.oauthToken }

    return (lhsToken != nil) == (rhsToken != nil) && lhs.server == rhs.server
      && lhsToken?.accessToken == rhsToken?.accessToken
  }

  public enum Version: String, Sendable {
    case v1, v2
  }

  public enum ClientError: Error {
    case unexpectedRequest
  }

  public enum OauthError: Error {
    case missingApp
    case invalidRedirectURL
  }

  public var id: String {
    critical.withLock {
      let isAuth = $0.oauthToken != nil
      return "\(isAuth)\(server)\($0.oauthToken?.createdAt ?? 0)"
    }
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }

  public let server: String
  public let version: Version
  private let session: Session
  private let decoder = JSONDecoder()

  private let logger = Logger(subsystem: "com.icecubesapp", category: "networking")

  // Putting all mutable state inside an `OSAllocatedUnfairLock` makes `Client`
  // provably `Sendable`. The lock is a struct, but it uses a `ManagedBuffer`
  // reference type to hold its associated state.
  private let critical: OSAllocatedUnfairLock<Critical>
  private struct Critical: Sendable {
    /// Only used as a transitionary app while in the oauth flow.
    var oauthApp: InstanceApp?
    var oauthToken: OauthToken?
    var connections: Set<String> = []
  }

  public var isAuth: Bool {
    critical.withLock { $0.oauthToken != nil }
  }

  public var connections: Set<String> {
    critical.withLock { $0.connections }
  }

  public init(server: String, version: Version = .v1, oauthToken: OauthToken? = nil) {
    self.server = server
    self.version = version
    critical = .init(initialState: Critical(oauthToken: oauthToken, connections: [server]))
    
    // Create Alamofire session with custom configuration
    let configuration = URLSessionConfiguration.default
    session = Session(configuration: configuration)
    
    decoder.keyDecodingStrategy = .convertFromSnakeCase
  }

  public func addConnections(_ connections: [String]) {
    critical.withLock {
      $0.connections.formUnion(connections)
    }
  }

  public func hasConnection(with url: URL) -> Bool {
    guard let host = url.host else { return false }
    return critical.withLock {
      if let rootHost = host.split(separator: ".", maxSplits: 1).last {
        // Sometimes the connection is with the root host instead of a subdomain
        // eg. Mastodon runs on mastdon.domain.com but the connection is with domain.com
        $0.connections.contains(host) || $0.connections.contains(String(rootHost))
      } else {
        $0.connections.contains(host)
      }
    }
  }

  private func makeURL(
    scheme: String = "https",
    endpoint: Endpoint,
    forceVersion: Version? = nil,
    forceServer: String? = nil
  ) throws -> URL {
    var components = URLComponents()
    components.scheme = scheme
    components.host = forceServer ?? server
    if type(of: endpoint) == Oauth.self {
      components.path += "/\(endpoint.path())"
    } else {
      components.path += "/api/\(forceVersion?.rawValue ?? version.rawValue)/\(endpoint.path())"
    }
    components.queryItems = endpoint.queryItems()
    guard let url = components.url else {
      throw ClientError.unexpectedRequest
    }
    return url
  }

  private func makeHeaders(endpoint: Endpoint) -> HTTPHeaders {
    var headers = HTTPHeaders()
    
    if let oauthToken = critical.withLock({ $0.oauthToken }) {
      headers.add(.authorization(bearerToken: oauthToken.accessToken))
    }
    
    if endpoint.jsonValue != nil {
      headers.add(.contentType("application/json"))
    }
    
    return headers
  }

  private func makeParameters(endpoint: Endpoint) throws -> Parameters? {
    guard let json = endpoint.jsonValue else { return nil }
    
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = .sortedKeys
    
    let jsonData = try encoder.encode(json)
    guard let dictionary = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
      return nil
    }
    
    return dictionary
  }

  private func makeEntityRequest<Entity: Decodable>(
    endpoint: Endpoint,
    method: HTTPMethod,
    forceVersion: Version? = nil
  ) async throws -> Entity {
    let url = try makeURL(endpoint: endpoint, forceVersion: forceVersion)
    let headers = makeHeaders(endpoint: endpoint)
    let parameters = try makeParameters(endpoint: endpoint)
    
    return try await withCheckedThrowingContinuation { continuation in
      let request = session.request(
        url,
        method: method,
        parameters: parameters,
        encoding: JSONEncoding.default,
        headers: headers
      )
      
      logger.log(level: .info, "\(request)")
      
      request.responseData { response in
        switch response.result {
        case .success(let data):
          self.logResponseOnError(httpResponse: response.response, data: data)
          do {
            let entity = try self.decoder.decode(Entity.self, from: data)
            continuation.resume(returning: entity)
          } catch {
            if var serverError = try? self.decoder.decode(ServerError.self, from: data) {
              if let httpResponse = response.response {
                serverError.httpCode = httpResponse.statusCode
              }
              continuation.resume(throwing: serverError)
            } else {
              continuation.resume(throwing: error)
            }
          }
        case .failure(let error):
          continuation.resume(throwing: error)
        }
      }
    }
  }

  public func get<Entity: Decodable>(endpoint: Endpoint, forceVersion: Version? = nil) async throws
    -> Entity
  {
    try await makeEntityRequest(endpoint: endpoint, method: .get, forceVersion: forceVersion)
  }

  public func getWithLink<Entity: Decodable>(endpoint: Endpoint) async throws -> (
    Entity, LinkHandler?
  ) {
    let url = try makeURL(endpoint: endpoint)
    let headers = makeHeaders(endpoint: endpoint)
    
    return try await withCheckedThrowingContinuation { continuation in
      let request = session.request(url, method: .get, headers: headers)
      
      request.responseData { response in
        var linkHandler: LinkHandler?
        if let link = response.response?.allHeaderFields["Link"] as? String {
          linkHandler = .init(rawLink: link)
        }
        
        switch response.result {
        case .success(let data):
          self.logResponseOnError(httpResponse: response.response, data: data)
          self.logger.log(level: .info, "\(request)")
          do {
            let entity = try self.decoder.decode(Entity.self, from: data)
            continuation.resume(returning: (entity, linkHandler))
          } catch {
            continuation.resume(throwing: error)
          }
        case .failure(let error):
          continuation.resume(throwing: error)
        }
      }
    }
  }

  public func post<Entity: Decodable>(endpoint: Endpoint, forceVersion: Version? = nil) async throws
    -> Entity
  {
    try await makeEntityRequest(endpoint: endpoint, method: .post, forceVersion: forceVersion)
  }

  public func post(endpoint: Endpoint, forceVersion: Version? = nil) async throws
    -> HTTPURLResponse?
  {
    let url = try makeURL(endpoint: endpoint, forceVersion: forceVersion)
    let headers = makeHeaders(endpoint: endpoint)
    let parameters = try makeParameters(endpoint: endpoint)
    
    return try await withCheckedThrowingContinuation { continuation in
      let request = session.request(
        url,
        method: .post,
        parameters: parameters,
        encoding: JSONEncoding.default,
        headers: headers
      )
      
      request.response { response in
        switch response.result {
        case .success:
          continuation.resume(returning: response.response)
        case .failure(let error):
          continuation.resume(throwing: error)
        }
      }
    }
  }

  public func patch(endpoint: Endpoint) async throws -> HTTPURLResponse? {
    let url = try makeURL(endpoint: endpoint)
    let headers = makeHeaders(endpoint: endpoint)
    let parameters = try makeParameters(endpoint: endpoint)
    
    return try await withCheckedThrowingContinuation { continuation in
      let request = session.request(
        url,
        method: .patch,
        parameters: parameters,
        encoding: JSONEncoding.default,
        headers: headers
      )
      
      request.response { response in
        switch response.result {
        case .success:
          continuation.resume(returning: response.response)
        case .failure(let error):
          continuation.resume(throwing: error)
        }
      }
    }
  }

  public func put<Entity: Decodable>(endpoint: Endpoint, forceVersion: Version? = nil) async throws
    -> Entity
  {
    try await makeEntityRequest(endpoint: endpoint, method: .put, forceVersion: forceVersion)
  }

  public func delete(endpoint: Endpoint, forceVersion: Version? = nil) async throws
    -> HTTPURLResponse?
  {
    let url = try makeURL(endpoint: endpoint, forceVersion: forceVersion)
    let headers = makeHeaders(endpoint: endpoint)
    
    return try await withCheckedThrowingContinuation { continuation in
      let request = session.request(url, method: .delete, headers: headers)
      
      request.response { response in
        switch response.result {
        case .success:
          continuation.resume(returning: response.response)
        case .failure(let error):
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private func makeEntityRequest<Entity: Decodable>(
    endpoint: Endpoint,
    method: HTTPMethod,
    forceVersion: Version? = nil
  ) async throws -> Entity {
    let url = try makeURL(endpoint: endpoint, forceVersion: forceVersion)
    let headers = makeHeaders(endpoint: endpoint)
    let parameters = try makeParameters(endpoint: endpoint)
    
    return try await withCheckedThrowingContinuation { continuation in
      let request = session.request(
        url,
        method: method,
        parameters: parameters,
        encoding: JSONEncoding.default,
        headers: headers
      )
      
      logger.log(level: .info, "\(request)")
      
      request.responseData { response in
        switch response.result {
        case .success(let data):
          self.logResponseOnError(httpResponse: response.response, data: data)
          do {
            let entity = try self.decoder.decode(Entity.self, from: data)
            continuation.resume(returning: entity)
          } catch {
            if var serverError = try? self.decoder.decode(ServerError.self, from: data) {
              if let httpResponse = response.response {
                serverError.httpCode = httpResponse.statusCode
              }
              continuation.resume(throwing: serverError)
            } else {
              continuation.resume(throwing: error)
            }
          }
        case .failure(let error):
          continuation.resume(throwing: error)
        }
      }
    }
  }

  public func makeWebSocketTask(endpoint: Endpoint, instanceStreamingURL: URL?) throws
    -> URLSessionWebSocketTask
  {
    // WebSocket support: Alamofire doesn't support WebSockets, so we continue using URLSession
    let url = try makeURL(
      scheme: "wss", endpoint: endpoint, forceServer: instanceStreamingURL?.host)
    var subprotocols: [String] = []
    if let oauthToken = critical.withLock({ $0.oauthToken }) {
      subprotocols.append(oauthToken.accessToken)
    }
    return URLSession.shared.webSocketTask(with: url, protocols: subprotocols)
  }

  public func oauthURL() async throws -> URL {
    let app: InstanceApp = try await post(endpoint: Apps.registerApp)
    critical.withLock { $0.oauthApp = app }
    return try makeURL(endpoint: Oauth.authorize(clientId: app.clientId))
  }

  public func continueOauthFlow(url: URL) async throws -> OauthToken {
    guard let app = critical.withLock({ $0.oauthApp }) else {
      throw OauthError.missingApp
    }
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let code = components.queryItems?.first(where: { $0.name == "code" })?.value
    else {
      throw OauthError.invalidRedirectURL
    }
    let token: OauthToken = try await post(
      endpoint: Oauth.token(
        code: code,
        clientId: app.clientId,
        clientSecret: app.clientSecret))
    critical.withLock { $0.oauthToken = token }
    return token
  }

  public func mediaUpload<Entity: Decodable>(
    endpoint: Endpoint,
    version: Version,
    method: String,
    mimeType: String,
    filename: String,
    data: Data
  ) async throws -> Entity {
    let url = try makeURL(endpoint: endpoint, forceVersion: version)
    let headers = makeHeaders(endpoint: endpoint)
    
    return try await withCheckedThrowingContinuation { continuation in
      let request = session.upload(
        multipartFormData: { multipartFormData in
          multipartFormData.append(data, withName: filename, fileName: filename, mimeType: mimeType)
        },
        to: url,
        method: HTTPMethod(rawValue: method) ?? .post,
        headers: headers
      )
      
      request.responseData { response in
        switch response.result {
        case .success(let responseData):
          self.logResponseOnError(httpResponse: response.response, data: responseData)
          do {
            let entity = try self.decoder.decode(Entity.self, from: responseData)
            continuation.resume(returning: entity)
          } catch {
            if let serverError = try? self.decoder.decode(ServerError.self, from: responseData) {
              continuation.resume(throwing: serverError)
            } else {
              continuation.resume(throwing: error)
            }
          }
        case .failure(let error):
          continuation.resume(throwing: error)
        }
      }
    }
  }

  public func mediaUpload(
    endpoint: Endpoint,
    version: Version,
    method: String,
    mimeType: String,
    filename: String,
    data: Data
  ) async throws -> HTTPURLResponse? {
    let url = try makeURL(endpoint: endpoint, forceVersion: version)
    let headers = makeHeaders(endpoint: endpoint)
    
    return try await withCheckedThrowingContinuation { continuation in
      let request = session.upload(
        multipartFormData: { multipartFormData in
          multipartFormData.append(data, withName: filename, fileName: filename, mimeType: mimeType)
        },
        to: url,
        method: HTTPMethod(rawValue: method) ?? .post,
        headers: headers
      )
      
      request.response { response in
        switch response.result {
        case .success:
          continuation.resume(returning: response.response)
        case .failure(let error):
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private func logResponseOnError(httpResponse: URLResponse?, data: Data) {
    if let httpResponse = httpResponse as? HTTPURLResponse, httpResponse.statusCode > 299 {
      let error =
        "HTTP Response error: \(httpResponse.statusCode), response: \(httpResponse), data: \(String(data: data, encoding: .utf8) ?? "")"
      logger.error("\(error)")
    }
  }
}
