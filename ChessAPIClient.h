#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, ChessAPIProvider) {
    ChessAPIProviderStockfishOnline = 0,   // depth 5–12
    ChessAPIProviderChessAPI        = 1,   // depth 1–18
    ChessAPIProviderOffline         = 2,   // Stockfish embedded trong app
};

@interface ChessAPIResult : NSObject
@property (nonatomic, copy)   NSString *bestMoveUCI;
@property (nonatomic, copy)   NSString *san;
@property (nonatomic, assign) NSInteger depth;
@property (nonatomic, copy)   NSString *rawResponse;
@property (nonatomic, assign) NSInteger httpStatus;
@end

@interface ChessAPIClient : NSObject

+ (instancetype)shared;

// Provider name ngắn để log ("SF"/"CA"/"OF")
+ (NSString *)shortNameForProvider:(ChessAPIProvider)p;
+ (NSString *)longNameForProvider:(ChessAPIProvider)p;
+ (NSInteger)minDepthForProvider:(ChessAPIProvider)p;
+ (NSInteger)maxDepthForProvider:(ChessAPIProvider)p;
+ (NSString *)extractUCIMove:(NSString *)raw;

- (NSURLSessionDataTask *)requestBestMoveForFEN:(NSString *)fen
                                          depth:(NSInteger)depth
                                       provider:(ChessAPIProvider)provider
                                     completion:(void (^)(ChessAPIResult *result, NSError *error))completion;

@end