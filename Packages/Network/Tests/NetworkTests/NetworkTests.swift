import XCTest
import Alamofire

@testable import Network

final class NetworkTests: XCTestCase {
  func testClientInitialization() throws {
    // Test that the Client can be initialized properly with Alamofire
    let client = Client(server: "mastodon.social")
    XCTAssertEqual(client.server, "mastodon.social")
    XCTAssertEqual(client.version, .v1)
    XCTAssertFalse(client.isAuth)
  }
  
  func testDeepLClientInitialization() throws {
    // Test that DeepLClient can be initialized
    let client = DeepLClient(userAPIKey: "test-key", userAPIFree: true)
    // Basic initialization test - the client should be created without errors
    XCTAssertNotNil(client)
  }
  
  func testOpenAIClientInitialization() throws {
    // Test that OpenAIClient can be initialized
    let client = OpenAIClient()
    // Basic initialization test - the client should be created without errors
    XCTAssertNotNil(client)
  }
  
  func testSubClubClientInitialization() throws {
    // Test that SubClubClient can be initialized
    let client = SubClubClient()
    // Basic initialization test - the client should be created without errors
    XCTAssertNotNil(client)
  }
  
  func testInstanceSocialClientInitialization() throws {
    // Test that InstanceSocialClient can be initialized
    let client = InstanceSocialClient()
    // Basic initialization test - the client should be created without errors
    XCTAssertNotNil(client)
  }
  
  func testClientAuthenticationState() throws {
    // Test authentication state changes
    let client = Client(server: "mastodon.social")
    XCTAssertFalse(client.isAuth)
    
    // Test with OAuth token
    let token = OauthToken(accessToken: "test-token", tokenType: "Bearer", scope: "read", createdAt: 0)
    let authenticatedClient = Client(server: "mastodon.social", oauthToken: token)
    XCTAssertTrue(authenticatedClient.isAuth)
  }
}
