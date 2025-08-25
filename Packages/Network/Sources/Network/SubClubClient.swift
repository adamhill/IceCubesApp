import Alamofire
import Foundation
import Models

public struct SubClubClient: Sendable {
  public enum Endpoint {
    case user(username: String)

    var path: String {
      switch self {
      case .user(let username):
        return "users/\(username)"
      }
    }
  }

  public init() {}

  private var url: String {
    "https://\(AppInfo.premiumInstance)/"
  }

  public func getUser(username: String) async -> SubClubUser? {
    guard let url = URL(string: url.appending(Endpoint.user(username: username).path)) else {
      return nil
    }
    
    return await withCheckedContinuation { continuation in
      AF.request(url, method: .get).responseData { response in
        switch response.result {
        case .success(let data):
          do {
            let decoder = JSONDecoder()
            let user = try decoder.decode(SubClubUser.self, from: data)
            continuation.resume(returning: user)
          } catch {
            continuation.resume(returning: nil)
          }
        case .failure:
          continuation.resume(returning: nil)
        }
      }
    }
  }
}
