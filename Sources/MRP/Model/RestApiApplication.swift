#if canImport(FlyingFox)
import FlyingFox

protocol RestApiApplication: Application {
  func registerRestApiHandlers(for httpServer: HTTPServer) async throws
}

#endif
