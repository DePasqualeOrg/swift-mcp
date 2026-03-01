// Copyright © Anthony DePasquale

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Client ID Metadata Documents (CIMD, SEP-991)

/// Checks whether a URL is valid for use as a Client ID Metadata Document URL.
///
/// Per SEP-991, the URL must use HTTPS and have a non-root path.
///
/// - Parameter url: The URL to validate
/// - Returns: `true` if the URL is valid for CIMD
public func isValidCIMDURL(_ url: URL) -> Bool {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
        return false
    }
    guard components.scheme?.lowercased() == "https" else {
        return false
    }
    let path = components.path
    return !path.isEmpty && path != "/"
}

/// Determines whether to use Client ID Metadata Documents (CIMD) instead
/// of Dynamic Client Registration.
///
/// CIMD is preferred when the authorization server advertises support
/// (`client_id_metadata_document_supported`) and a valid metadata URL
/// is available.
///
/// - Parameters:
///   - serverMetadata: The authorization server's metadata
///   - clientMetadataURL: The client's metadata document URL, if available
/// - Returns: `true` if CIMD should be used
public func shouldUseCIMD(
    serverMetadata: OAuthMetadata,
    clientMetadataURL: URL?
) -> Bool {
    guard serverMetadata.clientIdMetadataDocumentSupported == true else {
        return false
    }
    guard let clientMetadataURL else {
        return false
    }
    return isValidCIMDURL(clientMetadataURL)
}

/// Creates client information for a CIMD-based registration.
///
/// The URL itself becomes the `client_id`. No network request is needed –
/// the authorization server fetches and validates the metadata document
/// at the URL when the client presents it.
///
/// - Parameters:
///   - url: The client metadata document URL (becomes the `client_id`)
///   - redirectURIs: Redirect URIs from the client's metadata (inherited)
/// - Returns: Client information with the URL as `client_id`
public func clientInfoFromMetadataURL(_ url: URL, redirectURIs _: [URL]?) -> OAuthClientInformation {
    OAuthClientInformation(clientId: url.absoluteString)
}

// MARK: - Dynamic Client Registration (RFC 7591)

/// Registers a client with an authorization server via Dynamic Client
/// Registration (RFC 7591).
///
/// Sends the client's metadata to the registration endpoint and returns
/// the assigned client credentials.
///
/// - Parameters:
///   - clientMetadata: The client's metadata to register
///   - registrationEndpoint: The AS's registration endpoint URL
///   - httpClient: HTTP request handler (defaults to URLSession)
/// - Returns: The client information assigned by the server
/// - Throws: ``OAuthError/registrationFailed(_:)`` if registration fails,
///   or ``OAuthError/invalidClientMetadata(_:)`` if the server rejects the metadata
public func registerClient(
    clientMetadata: OAuthClientMetadata,
    registrationEndpoint: URL,
    httpClient: HTTPRequestHandler = defaultHTTPRequestHandler
) async throws -> OAuthClientInformation {
    var request = URLRequest(url: registrationEndpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    request.httpBody = try encoder.encode(clientMetadata)

    let (data, response) = try await httpClient(request)

    guard response.statusCode == 200 || response.statusCode == 201 else {
        if let errorResponse = try? JSONDecoder().decode(OAuthTokenErrorResponse.self, from: data) {
            throw OAuthError(from: errorResponse)
        }
        throw OAuthError.registrationFailed(
            "Registration endpoint returned HTTP \(response.statusCode)")
    }

    do {
        return try JSONDecoder().decode(OAuthClientInformation.self, from: data)
    } catch {
        throw OAuthError.registrationFailed(
            "Invalid registration response: \(error.localizedDescription)")
    }
}

/// Returns the registration endpoint URL from AS metadata.
///
/// When AS metadata is available but does not include a registration endpoint,
/// this throws an error because the AS has explicitly chosen not to support DCR.
/// When no metadata is available at all, falls back to `/register` on the
/// authorization server's origin.
///
/// - Parameters:
///   - metadata: The authorization server's metadata, if available
///   - authServerURL: The authorization server's base URL
/// - Returns: The registration endpoint URL
/// - Throws: ``OAuthError/registrationFailed(_:)`` if the AS metadata does not
///   include a registration endpoint
public func registrationEndpoint(
    from metadata: OAuthMetadata?,
    authServerURL: URL
) throws -> URL {
    if let metadata {
        guard let endpoint = metadata.registrationEndpoint else {
            throw OAuthError.registrationFailed(
                "Authorization server does not support dynamic client registration")
        }
        return endpoint
    }
    return rootRelativeURL("/register", on: authServerURL)
}
