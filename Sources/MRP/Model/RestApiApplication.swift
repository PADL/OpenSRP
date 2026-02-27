#if RestAPI
import FlyingFox

protocol RestApiApplication: Application {
  func registerRestApiHandlers(for httpServer: HTTPServer) async throws
}

#endif
