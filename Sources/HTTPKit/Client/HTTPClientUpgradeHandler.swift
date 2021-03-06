internal final class HTTPClientUpgradeHandler: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPResponse
    typealias OutboundIn = HTTPRequest
    typealias OutboundOut = HTTPRequest
    
    enum UpgradeState {
        case ready
        case pending(HTTPClientProtocolUpgrader)
    }

    var state: UpgradeState
    let httpHandlerNames: [String]

    init(
        httpHandlerNames: [String]
    ) {
        self.httpHandlerNames = httpHandlerNames
        self.state = .ready
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.fireChannelRead(data)
        switch self.state {
        case .pending(let upgrader):
            let res = self.unwrapInboundIn(data)
            if res.status == .switchingProtocols {
                let futures = [
                    context.pipeline.removeHandler(self)
                ] + self.httpHandlerNames.map { context.pipeline.removeHandler(name: $0) }
                EventLoopFuture<Void>.andAllSucceed(futures, on: context.eventLoop).flatMap { () -> EventLoopFuture<Void> in
                    return upgrader.upgrade(context: context, upgradeResponse: .init(
                        version: res.version,
                        status: res.status,
                        headers: res.headers
                    ))
                }.whenFailure { error in
                    self.errorCaught(context: context, error: error)
                }
                
            }
        case .ready: break
        }
    }
    
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        var req = self.unwrapOutboundIn(data)
        if let upgrader = req.upgrader {
            for (name, value) in upgrader.buildUpgradeRequest() {
                req.headers.add(name: name, value: value)
            }
            self.state = .pending(upgrader)
        }
        context.write(self.wrapOutboundOut(req), promise: promise)
    }
}
