import Darwin
import Foundation
import Network

/// Opens the Soulseek listening port on the home router so peers can
/// connect back to the phone. Tries NAT-PMP (Apple and many other routers),
/// then UPnP IGD via a unicast SSDP query to the gateway (multicast needs a
/// special entitlement on iOS).
enum PortMapper {
    struct Mapping {
        let method: String
        let externalPort: UInt16
    }

    static func map(port: UInt16) async -> Mapping? {
        guard let local = localIPv4() else { return nil }
        let gateway = local.split(separator: ".").prefix(3).joined(separator: ".") + ".1"
        if let external = await natPMP(gateway: gateway, port: port) {
            return Mapping(method: "NAT-PMP", externalPort: external)
        }
        if await upnp(gateway: gateway, localIP: local, port: port) {
            return Mapping(method: "UPnP", externalPort: port)
        }
        return nil
    }

    // MARK: NAT-PMP (RFC 6886)

    private static func natPMP(gateway: String, port: UInt16) async -> UInt16? {
        var request = Data([0, 2, 0, 0]) // version 0, map TCP, reserved
        request.append(contentsOf: [UInt8(port >> 8), UInt8(port & 0xFF)]) // internal
        request.append(contentsOf: [UInt8(port >> 8), UInt8(port & 0xFF)]) // suggested external
        request.append(contentsOf: [0, 0, 0x0E, 0x10]) // lifetime 3600 s
        guard let reply = await udpExchange(host: gateway, port: 5351, payload: request, timeout: 2),
              reply.count >= 16, reply[1] == 130, reply[2] == 0, reply[3] == 0 else { return nil }
        return UInt16(reply[10]) << 8 | UInt16(reply[11])
    }

    // MARK: UPnP IGD

    private static func upnp(gateway: String, localIP: String, port: UInt16) async -> Bool {
        let search = """
        M-SEARCH * HTTP/1.1\r
        HOST: 239.255.255.250:1900\r
        MAN: "ssdp:discover"\r
        MX: 2\r
        ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r
        \r

        """
        guard let reply = await udpExchange(host: gateway, port: 1900, payload: Data(search.utf8), timeout: 3),
              let text = String(data: reply, encoding: .utf8),
              let locationLine = text.components(separatedBy: "\r\n")
                .first(where: { $0.lowercased().hasPrefix("location:") }),
              let location = URL(string: locationLine.dropFirst("location:".count).trimmingCharacters(in: .whitespaces)),
              let (descriptionData, _) = try? await URLSession.shared.data(from: location),
              let description = String(data: descriptionData, encoding: .utf8) else { return false }

        let services = ["urn:schemas-upnp-org:service:WANIPConnection:2",
                        "urn:schemas-upnp-org:service:WANIPConnection:1",
                        "urn:schemas-upnp-org:service:WANPPPConnection:1"]
        for service in services {
            guard let range = description.range(of: "<serviceType>\(service)</serviceType>"),
                  let control = value(of: "controlURL", in: String(description[range.upperBound...])),
                  let controlURL = URL(string: control, relativeTo: location)?.absoluteURL else { continue }
            let body = """
            <?xml version="1.0"?>
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
            <s:Body><u:AddPortMapping xmlns:u="\(service)">
            <NewRemoteHost></NewRemoteHost>
            <NewExternalPort>\(port)</NewExternalPort>
            <NewProtocol>TCP</NewProtocol>
            <NewInternalPort>\(port)</NewInternalPort>
            <NewInternalClient>\(localIP)</NewInternalClient>
            <NewEnabled>1</NewEnabled>
            <NewPortMappingDescription>Playbox Music</NewPortMappingDescription>
            <NewLeaseDuration>3600</NewLeaseDuration>
            </u:AddPortMapping></s:Body></s:Envelope>
            """
            var request = URLRequest(url: controlURL)
            request.httpMethod = "POST"
            request.httpBody = Data(body.utf8)
            request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
            request.setValue("\"\(service)#AddPortMapping\"", forHTTPHeaderField: "SOAPAction")
            request.timeoutInterval = 4
            if let (_, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return true
            }
        }
        return false
    }

    private static func value(of tag: String, in xml: String) -> String? {
        guard let start = xml.range(of: "<\(tag)>"), let end = xml.range(of: "</\(tag)>", range: start.upperBound..<xml.endIndex)
        else { return nil }
        return String(xml[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Helpers

    private static func udpExchange(host: String, port: UInt16, payload: Data, timeout: TimeInterval) async -> Data? {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .udp)
        let once = OnceFlag()
        return await withCheckedContinuation { continuation in
            let finish: (Data?) -> Void = { data in
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(returning: data)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: payload, completion: .contentProcessed { error in
                        if error != nil { finish(nil) }
                    })
                    connection.receiveMessage { data, _, _, _ in finish(data) }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    /// The phone's Wi-Fi IPv4 address.
    static func localIPv4() -> String? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
        defer { freeifaddrs(addresses) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let interface = current.pointee
            if let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
               String(cString: interface.ifa_name) == "en0" {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(address, socklen_t(address.pointee.sa_len),
                            &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                return String(cString: host)
            }
            pointer = interface.ifa_next
        }
        return nil
    }
}
