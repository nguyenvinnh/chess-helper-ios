#import "ChessAPIClient.h"
#import "ChessOfflineEngineClient.h"

@implementation ChessAPIResult
@end

static inline NSInteger Clamp(NSInteger v, NSInteger lo, NSInteger hi) {
    return MAX(lo, MIN(hi, v));
}

static NSRegularExpression *UCIRegex(void) {
    static NSRegularExpression *re = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"([a-h][1-8][a-h][1-8][qrbn]?)"
                                                       options:0 error:nil];
    });
    return re;
}

static NSURLSession *SharedSession(void) {
    static NSURLSession *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *c = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        c.timeoutIntervalForRequest = 15.0;
        c.timeoutIntervalForResource = 20.0;
        c.HTTPMaximumConnectionsPerHost = 4;
        c.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        s = [NSURLSession sessionWithConfiguration:c];
    });
    return s;
}

static NSString *ExtractUCIMove(NSString *raw) {
    if (raw.length < 4) return nil;
    NSString *s = [raw lowercaseString];
    NSRegularExpression *re = UCIRegex();
    if (!re) return nil;
    NSTextCheckingResult *m = [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    if (!m) return nil;
    return [s substringWithRange:[m rangeAtIndex:1]];
}

static NSError *MakeDetailedError(ChessAPIProvider provider,
                                  NSInteger depth,
                                  NSInteger code,
                                  NSString *reason,
                                  NSHTTPURLResponse *httpResp,
                                  NSData *rawData,
                                  NSError *underlying) {
    NSString *provName = [ChessAPIClient longNameForProvider:provider];
    NSMutableString *desc = [NSMutableString stringWithFormat:@"%@ d=%ld: %@", provName, (long)depth, reason ?: @"?"];
    NSMutableDictionary *ui = [NSMutableDictionary dictionary];
    if (httpResp) {
        [desc appendFormat:@" [HTTP %ld]", (long)httpResp.statusCode];
        ui[@"HTTPStatus"] = @(httpResp.statusCode);
    }
    if (rawData.length > 0) {
        NSString *raw = [[NSString alloc] initWithData:rawData encoding:NSUTF8StringEncoding];
        if (raw.length > 0) {
            NSString *snippet = raw.length > 300 ? [[raw substringToIndex:300] stringByAppendingString:@"..."] : raw;
            ui[@"RawResponse"] = snippet;
            NSString *shortSnip = snippet.length > 90 ? [[snippet substringToIndex:90] stringByAppendingString:@"..."] : snippet;
            [desc appendFormat:@" raw=%@", shortSnip];
        }
    }
    if (underlying) {
        ui[NSUnderlyingErrorKey] = underlying;
        [desc appendFormat:@" underlying=%@", underlying.localizedDescription];
    }
    ui[@"Provider"] = provName;
    ui[@"Depth"] = @(depth);
    ui[NSLocalizedDescriptionKey] = desc;
    return [NSError errorWithDomain:@"ChessAPI" code:code userInfo:ui];
}

@interface ChessAPIClient ()
- (NSURLSessionDataTask *)callStockfishOnline:(NSString *)fen
                                        depth:(NSInteger)depth
                                   completion:(void (^)(ChessAPIResult *, NSError *))completion;
- (NSURLSessionDataTask *)callChessAPI:(NSString *)fen
                                 depth:(NSInteger)depth
                            completion:(void (^)(ChessAPIResult *, NSError *))completion;
@end

@implementation ChessAPIClient

+ (instancetype)shared {
    static ChessAPIClient *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [ChessAPIClient new]; });
    return s;
}

+ (NSString *)shortNameForProvider:(ChessAPIProvider)p {
    switch (p) {
        case ChessAPIProviderStockfishOnline: return @"SF";
        case ChessAPIProviderChessAPI: return @"CA";
        case ChessAPIProviderOffline: return @"OF";
    }
    return @"?";
}

+ (NSString *)longNameForProvider:(ChessAPIProvider)p {
    switch (p) {
        case ChessAPIProviderStockfishOnline: return @"Stockfish";
        case ChessAPIProviderChessAPI: return @"Chess-API";
        case ChessAPIProviderOffline: return @"Offline";
    }
    return @"?";
}

+ (NSInteger)minDepthForProvider:(ChessAPIProvider)p {
    switch (p) {
        case ChessAPIProviderStockfishOnline: return 5;
        case ChessAPIProviderChessAPI: return 1;
        case ChessAPIProviderOffline: return 1;
    }
    return 1;
}

+ (NSInteger)maxDepthForProvider:(ChessAPIProvider)p {
    switch (p) {
        case ChessAPIProviderStockfishOnline: return 12;
        case ChessAPIProviderChessAPI: return 18;
        case ChessAPIProviderOffline: return 30;
    }
    return 18;
}

+ (NSString *)extractUCIMove:(NSString *)raw {
    return ExtractUCIMove(raw);
}

- (NSURLSessionDataTask *)requestBestMoveForFEN:(NSString *)fen
                                          depth:(NSInteger)depth
                                       provider:(ChessAPIProvider)provider
                                     completion:(void (^)(ChessAPIResult *, NSError *))completion {
    if (fen.length == 0) {
        if (completion) completion(nil, MakeDetailedError(provider, depth, -1, @"FEN rong", nil, nil, nil));
        return nil;
    }
    switch (provider) {
        case ChessAPIProviderStockfishOnline:
            return [self callStockfishOnline:fen depth:Clamp(depth, 5, 12) completion:completion];
        case ChessAPIProviderChessAPI:
            return [self callChessAPI:fen depth:Clamp(depth, 1, 18) completion:completion];
        case ChessAPIProviderOffline:
            return [[ChessOfflineEngineClient shared] requestBestMoveForFEN:fen depth:depth completion:completion];
    }
    return nil;
}

- (NSURLSessionDataTask *)callStockfishOnline:(NSString *)fen
                                        depth:(NSInteger)depth
                                   completion:(void (^)(ChessAPIResult *, NSError *))completion {
    NSString *encoded = [fen stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *urlStr = [NSString stringWithFormat:@"https://stockfish.online/api/s/v2.php?fen=%@&depth=%ld", encoded, (long)depth];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        if (completion) completion(nil, MakeDetailedError(ChessAPIProviderStockfishOnline, depth, -2, @"URL khong hop le", nil, nil, nil));
        return nil;
    }
    NSURLSessionDataTask *task = [SharedSession() dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSHTTPURLResponse *http = [resp isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)resp : nil;
        if (err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(nil, MakeDetailedError(ChessAPIProviderStockfishOnline, depth, -10, @"Network error", http, data, err));
            });
            return;
        }
        if (http.statusCode == 429) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(nil, MakeDetailedError(ChessAPIProviderStockfishOnline, depth, -20, @"Rate limit (429)", http, data, nil));
            });
            return;
        }
        if (http.statusCode >= 400) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(nil, MakeDetailedError(ChessAPIProviderStockfishOnline, depth, -21, [NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode], http, data, nil));
            });
            return;
        }
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        ChessAPIResult *result = [ChessAPIResult new];
        result.depth = depth;
        result.httpStatus = http.statusCode;
        result.rawResponse = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
        if ([json isKindOfClass:[NSDictionary class]]) {
            NSDictionary *d = (NSDictionary *)json;
            id success = d[@"success"];
            if ([success respondsToSelector:@selector(boolValue)] && ![success boolValue]) {
                NSString *why = d[@"data"] ?: d[@"message"] ?: @"success=false";
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completion) completion(nil, MakeDetailedError(ChessAPIProviderStockfishOnline, depth, -22, [NSString stringWithFormat:@"Engine: %@", why], http, data, nil));
                });
                return;
            }
            NSString *best = d[@"bestmove"] ?: d[@"bestMove"] ?: d[@"move"];
            if ([best isKindOfClass:[NSString class]]) result.bestMoveUCI = ExtractUCIMove(best);
            if (!result.bestMoveUCI) result.bestMoveUCI = ExtractUCIMove(result.rawResponse);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (result.bestMoveUCI.length > 0) {
                if (completion) completion(result, nil);
            } else {
                if (completion) completion(nil, MakeDetailedError(ChessAPIProviderStockfishOnline, depth, -30, @"Khong parse duoc bestmove", http, data, nil));
            }
        });
    }];
    [task resume];
    return task;
}

- (NSURLSessionDataTask *)callChessAPI:(NSString *)fen
                                 depth:(NSInteger)depth
                            completion:(void (^)(ChessAPIResult *, NSError *))completion {
    NSURL *url = [NSURL URLWithString:@"https://chess-api.com/v1"];
    if (!url) {
        if (completion) completion(nil, MakeDetailedError(ChessAPIProviderChessAPI, depth, -4, @"URL khong hop le", nil, nil, nil));
        return nil;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"fen": fen, @"depth": @(depth)} options:0 error:nil];
    NSURLSessionDataTask *task = [SharedSession() dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSHTTPURLResponse *http = [resp isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)resp : nil;
        if (err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(nil, MakeDetailedError(ChessAPIProviderChessAPI, depth, -10, @"Network error", http, data, err));
            });
            return;
        }
        if (http.statusCode == 429) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(nil, MakeDetailedError(ChessAPIProviderChessAPI, depth, -20, @"Rate limit (429)", http, data, nil));
            });
            return;
        }
        if (http.statusCode >= 400) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(nil, MakeDetailedError(ChessAPIProviderChessAPI, depth, -21, [NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode], http, data, nil));
            });
            return;
        }
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        ChessAPIResult *result = [ChessAPIResult new];
        result.depth = depth;
        result.httpStatus = http.statusCode;
        result.rawResponse = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
        if ([json isKindOfClass:[NSDictionary class]]) {
            NSDictionary *d = (NSDictionary *)json;
            if (d[@"error"]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completion) completion(nil, MakeDetailedError(ChessAPIProviderChessAPI, depth, -22, [NSString stringWithFormat:@"API: %@", d[@"error"]], http, data, nil));
                });
                return;
            }
            NSString *best = d[@"move"] ?: d[@"bestmove"] ?: d[@"bestMove"];
            if ([best isKindOfClass:[NSString class]]) {
                result.bestMoveUCI = ExtractUCIMove(best);
                result.san = best;
            }
            if (!result.bestMoveUCI) result.bestMoveUCI = ExtractUCIMove(result.rawResponse);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (result.bestMoveUCI.length > 0) {
                if (completion) completion(result, nil);
            } else {
                if (completion) completion(nil, MakeDetailedError(ChessAPIProviderChessAPI, depth, -30, @"Khong parse duoc bestmove", http, data, nil));
            }
        });
    }];
    [task resume];
    return task;
}

@end
