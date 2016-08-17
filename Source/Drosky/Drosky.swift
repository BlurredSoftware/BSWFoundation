//
//  Created by Pierluigi Cifani on 03/06/15.
//  Copyright (c) 2016 Blurred Software SL. All rights reserved.
//

import Foundation
import Alamofire
import Deferred

/*
 Welcome to Drosky, your one and only way of talking to Rest APIs.
 
 Inspired by Moya (https://github.com/AshFurrow/Moya)
 
 */

/*
 Things to improve:
 1.- Wrap the network calls in a NSOperation in order to:
 * Control how many are being sent at the same time
 * Allow to add priorities in order to differentiate user facing calls to analytics crap
 2.- Use the Timeline data in Response to calculate an average of the responses from the server
 */


// Mark: HTTP method and parameter encoding

public enum HTTPMethod: String {
    case GET, POST, PUT, DELETE, OPTIONS, HEAD, PATCH, TRACE, CONNECT
}

extension HTTPMethod {
    func alamofireMethod() -> Alamofire.Method {
        switch self {
        case GET:
            return .GET
        case POST:
            return .POST
        case PUT:
            return .PUT
        case DELETE:
            return .DELETE
        case OPTIONS:
            return .OPTIONS
        case HEAD:
            return .HEAD
        case PATCH:
            return .PATCH
        case TRACE:
            return .TRACE
        case CONNECT:
            return .CONNECT
        }
    }
}

public enum HTTPParameterEncoding {
    case URL
    case JSON
    case PropertyList(NSPropertyListFormat, NSPropertyListWriteOptions)
    case Custom((URLRequestConvertible, [String: AnyObject]?) -> (NSMutableURLRequest, NSError?))
}

extension HTTPParameterEncoding {
    func alamofireParameterEncoding() -> Alamofire.ParameterEncoding {
        switch self {
        case .URL:
            return .URL
        case .JSON:
            return .JSON
        case .PropertyList(let format, let options):
            return .PropertyList(format, options)
        case .Custom(let closure):
            return .Custom(closure)
        }
    }
}

// MARK:- DroskyResponse

public struct DroskyResponse {
    public let statusCode: Int
    public let httpHeaderFields: [String: String]
    public let data: NSData
}

extension DroskyResponse {
    func dataAsJSON() -> [String: AnyObject]? {
        let json: [String: AnyObject]?
        
        do {
            json = try NSJSONSerialization.JSONObjectWithData(self.data, options: NSJSONReadingOptions.AllowFragments) as? [String: AnyObject]
        } catch {
            json = nil
        }
        
        return json
    }
}

extension DroskyResponse: CustomStringConvertible {
    public var description: String {
        return "StatusCode: " + String(statusCode) + "\nHeaders: " +  httpHeaderFields.description
    }
}


// MARK:- Router

public typealias Signature = (header: String, value: String)

struct Router {
    let environment: Environment
    let signature: Signature?
    
    func urlRequestForEndpoint(endpoint: Endpoint) -> Result<URLRequestConvertible> {
        guard let URL = NSURL(string: environment.routeURL(endpoint.path)) else {
            return Result<URLRequestConvertible>(error: DroskyErrorKind.MalformedURLError)
        }
        
        let request = NSMutableURLRequest(URL: URL)
        request.HTTPMethod = endpoint.method.alamofireMethod().rawValue
        request.allHTTPHeaderFields = endpoint.httpHeaderFields
        if let signature = self.signature {
            request.setValue(signature.value, forHTTPHeaderField: signature.header)
        }
        
        let requestTuple = endpoint.parameterEncoding.alamofireParameterEncoding().encode(request, parameters: endpoint.parameters)
        
        if let error = requestTuple.1 {
            return Result<URLRequestConvertible>(error: error)
        } else {
            return Result<URLRequestConvertible>(requestTuple.0)
        }
    }
}

// MARK: - Drosky

public final class Drosky {
    
    private static let ModuleName = "drosky"
    private let networkManager: Alamofire.Manager
    private let backgroundNetworkManager: Alamofire.Manager
    private let queue = queueForSubmodule(Drosky.ModuleName, qualityOfService: .UserInitiated)
    private let gcdQueue = dispatch_queue_create(Drosky.ModuleName, DISPATCH_QUEUE_SERIAL)
    private let dataSerializer = Alamofire.Request.dataResponseSerializer()
    var router: Router
    
    public init (
        environment: Environment,
        signature: Signature? = nil,
        backgroundSessionID: String = Drosky.backgroundID(),
        trustedHosts: [String] = []) {
        
        let serverTrustPolicies = Drosky.serverTrustPoliciesDisablingEvaluationForHosts(trustedHosts)
        
        let serverTrustManager = ServerTrustPolicyManager(policies: serverTrustPolicies)
        
        networkManager = Alamofire.Manager(
            configuration: NSURLSessionConfiguration.defaultSessionConfiguration(),
            serverTrustPolicyManager: serverTrustManager
        )
        
        backgroundNetworkManager = Alamofire.Manager(
            configuration: NSURLSessionConfiguration.backgroundSessionConfigurationWithIdentifier(backgroundSessionID),
            serverTrustPolicyManager: serverTrustManager
        )
        router = Router(environment: environment, signature: signature)
        queue.underlyingQueue = gcdQueue
    }
    
    public func setAuthSignature(signature: Signature?) {
        router = Router(environment: router.environment, signature: signature)
    }

    public func setEnvironment(environment: Environment) {
        router = Router(environment: environment, signature: router.signature)
    }
    
    private static func serverTrustPoliciesDisablingEvaluationForHosts(hosts: [String]) -> [String: ServerTrustPolicy] {
        var policies = [String: ServerTrustPolicy]()
        hosts.forEach { policies[$0] = .DisableEvaluation }
        return policies
    }

    public func performRequest(forEndpoint endpoint: Endpoint) -> Future<Result<DroskyResponse>> {
        return generateRequest(endpoint)
                ≈> sendRequest
                ≈> processResponse
    }

    public func performAndValidateRequest(forEndpoint endpoint: Endpoint) -> Future<Result<DroskyResponse>> {
        return performRequest(forEndpoint: endpoint)
                ≈> validateDroskyResponse
    }

    public func performMultipartUpload(forEndpoint endpoint: Endpoint, multipartParams: [MultipartParameter]) -> (Future<Result<DroskyResponse>>, Future<NSProgress>) {
        let generatedRequest = try! router.urlRequestForEndpoint(endpoint).dematerialize()
        let multipartRequestTuple = performUpload(generatedRequest, multipartParameters: multipartParams)
        let processedResponse = multipartRequestTuple.0 ≈> processResponse
        return (processedResponse, multipartRequestTuple.1)
    }

    //MARK:- Internal
    private func generateRequest(endpoint: Endpoint) -> Future<Result<URLRequestConvertible>> {
        let deferred = Deferred<Result<URLRequestConvertible>>()
        queue.addOperationWithBlock { [weak self] in
            guard let strongSelf = self else { return }
            let requestResult = strongSelf.router.urlRequestForEndpoint(endpoint)
            deferred.fill(requestResult)
        }
        return Future(deferred)
    }
    
    
    private func sendRequest(request: URLRequestConvertible) -> Future<Result<(NSData, NSHTTPURLResponse)>> {
        let deferred = Deferred<Result<(NSData, NSHTTPURLResponse)>>()
        
        networkManager
            .request(request)
            .responseData(queue: gcdQueue) { self.processAlamofireResponse($0, deferred: deferred) }
        
        return Future(deferred)
    }
    
    private func performUpload(request: URLRequestConvertible, multipartParameters: [MultipartParameter]) -> (Future<Result<(NSData, NSHTTPURLResponse)>>, Future<NSProgress>) {
        let deferredResponse = Deferred<Result<(NSData, NSHTTPURLResponse)>>()
        let deferredProgress = Deferred<NSProgress>()
        
        backgroundNetworkManager.upload(
            request,
            multipartFormData: { (form) in
                multipartParameters.forEach { param in
                    form.appendBodyPart(fileURL: param.fileURL, name: param.parameterKey)
                }
            },
            encodingCompletion: { (result) in
                switch result {
                case .Failure(let error):
                    deferredResponse.fill(Result(error: error))
                case .Success(let request, _,  _):
                    deferredProgress.fill(request.progress)
                    request.responseData(queue: self.gcdQueue) {
                        self.processAlamofireResponse($0, deferred: deferredResponse)
                    }
                }
            }
        )
        
        return (Future(deferredResponse), Future(deferredProgress))
    }
    
    private func processResponse(data: NSData, urlResponse: NSHTTPURLResponse) -> Future<Result<DroskyResponse>> {
        
        let deferred = Deferred<Result<DroskyResponse>>()
        
        queue.addOperationWithBlock {
            if let responseHeaders = urlResponse.allHeaderFields as? [String: String] {

                let droskyResponse = DroskyResponse(
                    statusCode: urlResponse.statusCode,
                    httpHeaderFields: responseHeaders,
                    data: data
                )
                
                #if DEBUG
                    if let message = JSONParser.errorMessageFromData(droskyResponse.data) {
                        print(message)
                    }
                #endif

                let result = Result(droskyResponse)
                deferred.fill(result)
            }
            else {
                deferred.fill(Result(error: DroskyErrorKind.UnknownResponse))
            }
        }
        
        return Future(deferred)
    }
    
    private func validateDroskyResponse(response: DroskyResponse) -> Future<Result<DroskyResponse>> {
        
        let deferred = Deferred<Result<DroskyResponse>>()
        
        queue.addOperationWithBlock {
            switch response.statusCode {
            case 400:
                let error = DroskyErrorKind.BadRequest
                deferred.fill(Result<DroskyResponse>(error: error))
            case 401:
                let error = DroskyErrorKind.Unauthorized
                deferred.fill(Result<DroskyResponse>(error: error))
            case 403:
                let error = DroskyErrorKind.Forbidden
                deferred.fill(Result<DroskyResponse>(error: error))
            case 404:
                let error = DroskyErrorKind.ResourceNotFound
                deferred.fill(Result<DroskyResponse>(error: error))
            case 405...499:
                let error = DroskyErrorKind.UnknownResponse
                deferred.fill(Result<DroskyResponse>(error: error))
            case 500:
                let error = DroskyErrorKind.ServerUnavailable
                deferred.fill(Result<DroskyResponse>(error: error))
            default:
                deferred.fill(Result<DroskyResponse>(response))
            }
        }
        
        return Future(deferred)
    }

    private func processAlamofireResponse(response: Alamofire.Response<NSData, NSError>, deferred: Deferred<Result<(NSData, NSHTTPURLResponse)>>) {
        switch response.result {
        case .Failure(let error):
            deferred.fill(Result(error: error))
        case .Success(let data):
            guard let response = response.response else { fatalError() }
            deferred.fill(Result(value: (data, response)))
        }
    }
}

//MARK: Background handling

extension Drosky {
    
    private static func backgroundID() -> String {
        let appName = NSBundle.mainBundle().infoDictionary?[kCFBundleNameKey as String] as? String ?? Drosky.ModuleName
        return "\(appName)-\(NSUUID().UUIDString)"
    }

    public var backgroundSessionID: String {
        get {
            guard let sessionID = backgroundNetworkManager.session.configuration.identifier else { fatalError("This should have a sessionID") }
            return sessionID
        }
    }
    
    public func completedBackgroundTasksURL() -> Future<[NSURL]> {
        
        let deferred = Deferred<[NSURL]>()
        
        backgroundNetworkManager.delegate.sessionDidFinishEventsForBackgroundURLSession = { session in
            
            session.getTasksWithCompletionHandler { (dataTasks, _, _) -> Void in
                let completedTasks = dataTasks.filter { $0.state == .Completed && $0.originalRequest?.URL != nil}
                deferred.fill(completedTasks.map { return $0.originalRequest!.URL!})
                self.backgroundNetworkManager.backgroundCompletionHandler?()
            }
        }
        
        return Future(deferred)
    }

}

//MARK:- Errors

public enum DroskyErrorKind: ResultErrorType {
    case UnknownResponse
    case Unauthorized
    case ServerUnavailable
    case ResourceNotFound
    case FormattedError
    case MalformedURLError
    case Forbidden
    case BadRequest
}
