import BinaryResources
import Foundation
import GRPC
import GRPCImageServiceModels
import NIO
import NIOSSL

final class Upstream {
  let channel: GRPCChannel
  let client: ImageGenerationServiceNIOClient

  init(host: String, port: Int, TLS: Bool, group: EventLoopGroup) throws {
    let transportSecurity: GRPCChannelPool.Configuration.TransportSecurity
    if TLS {
      let certificate = try NIOSSLCertificate(
        bytes: [UInt8](BinaryResources.root_ca_crt), format: .pem)

      transportSecurity = .tls(
        .makeClientConfigurationBackedByNIOSSL(
          trustRoots: .certificates([certificate]),
          certificateVerification: .noHostnameVerification))
    } else {
      transportSecurity = .plaintext
    }
    var configuration = GRPCChannelPool.Configuration.with(
      target: .host(host, port: port), transportSecurity: transportSecurity,
      eventLoopGroup: group)
    configuration.maximumReceiveMessageLength = 1024 * 1024 * 1024
    channel = try GRPCChannelPool.with(configuration: configuration)
    client = ImageGenerationServiceNIOClient(channel: channel)
  }
}
