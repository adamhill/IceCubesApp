import Alamofire
import Foundation
import Models

public struct InstanceSocialClient: Sendable {
  private let authorization =
    "Bearer 8a4xx3D7Hzu1aFnf18qlkH8oU0oZ5ulabXxoS2FtQtwOy8G0DGQhr5PjTIjBnYAmFrSBuE2CcASjFocxJBonY8XGbLySB7MXd9ssrwlRHUXTQh3Z578lE1OfUtafvhML"
  private let listEndpoint =
    "https://instances.social/api/1.0/instances/list?count=1000&include_closed=false&include_dead=false&min_active_users=500"
  private let searchEndpoint = "https://instances.social/api/1.0/instances/search"

  struct Response: Decodable {
    let instances: [InstanceSocial]
  }

  public init() {}

  public func fetchInstances(keyword: String) async -> [InstanceSocial] {
    let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    let endpoint = keyword.isEmpty ? listEndpoint : searchEndpoint + "?q=\(keyword)"
    
    guard let url = URL(string: endpoint) else { return [] }
    
    let headers: HTTPHeaders = [
      "Authorization": authorization
    ]
    
    return await withCheckedContinuation { continuation in
      AF.request(url, method: .get, headers: headers).responseData { response in
        switch response.result {
        case .success(let data):
          do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let decodedResponse = try decoder.decode(Response.self, from: data)
            let result = decodedResponse.instances.sorted(by: keyword)
            continuation.resume(returning: result)
          } catch {
            continuation.resume(returning: [])
          }
        case .failure:
          continuation.resume(returning: [])
        }
      }
    }
  }
}

extension Array where Self.Element == InstanceSocial {
  fileprivate func sorted(by keyword: String) -> Self {
    let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    var newArray = self

    newArray.sort { (lhs: InstanceSocial, rhs: InstanceSocial) in
      guard
        let lhsNumber = Int(lhs.users),
        let rhsNumber = Int(rhs.users)
      else { return false }

      return lhsNumber > rhsNumber
    }

    newArray.sort { (lhs: InstanceSocial, rhs: InstanceSocial) in
      guard
        let lhsNumber = Int(lhs.statuses),
        let rhsNumber = Int(rhs.statuses)
      else { return false }

      return lhsNumber > rhsNumber
    }

    if !keyword.isEmpty {
      newArray.sort { (lhs: InstanceSocial, rhs: InstanceSocial) in
        if lhs.name.contains(keyword),
          !rhs.name.contains(keyword)
        {
          return true
        }

        return false
      }
    }

    return newArray
  }
}
