//
//  Stream.m
//  Eko
//
//  Created by David Zhang on 12/7/13.
//
//

#import "Stream.h"
#import "StreamPackets.h"

static NSString *const kSessionIDKey = @"sessionId";
static const NSInteger kSessionMinLength = 20;

@interface Stream ()

- (NSString *)getSIDFromServerCookie:(NSString *)cookie;
- (BOOL)isValidSID:(NSString *)sid;

@end

@implementation Stream

#pragma mark - Private functions

- (NSString *)getSIDFromServerCookie:(NSString *)cookie
{
    if(cookie.length < 15){
        return nil;
    }

    // append headers for the server
    return [NSString stringWithFormat:@"s:%@.e", cookie];
}

- (BOOL)isValidSID:(NSString *)sid
{
    if (sid.length > kSessionMinLength &&
        [sid characterAtIndex:0] == 's' && [sid characterAtIndex:1] == ':' &&
        [sid characterAtIndex:sid.length-1] == 'e' &&
        [sid characterAtIndex:sid.length-2] == '.') {
        return YES;
    }
    NSLog(@"Invalid SID stored: %@", sid);
    return NO;
}

#pragma mark - Instance functions

- (id)initWithHost:(NSString *)host port:(NSInteger)port secure:(BOOL)secure
{
    self = [super init];
    if (self) {
        // set defaults
        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@://%@:%d/engine.io/default/?transport=websocket", secure ? @"wss" : @"ws", host, port]];
        socket = [[Socket alloc] initWithURL:url];
        socket.delegate = self;
        
        // initialize datastructures
        bindCallbacks = [[NSMutableDictionary alloc] init];
        rpcCallbacks = [[NSMutableDictionary alloc] init];
        rpcId = 1;
        
        // load session id from local file
        sessionId = nil;
        id sid = [[NSUserDefaults standardUserDefaults] objectForKey:kSessionIDKey];
        if (sid && [sid isKindOfClass:[NSString class]] && [self isValidSID:sid]) {
            sessionId = sid;
            NSLog(@"Stored session ID: %@", sessionId);
        }
    }
    return self;
}

#pragma mark - Socket delegate protocol methods

- (void)didReceiveMessage:(NSString *)message
{
    @try {
        // seperate out the message type and data
        NSArray *split = [message componentsSeparatedByString:@"|"];
        if (split.count < 2) {
            if([split[0] characterAtIndex:0] == '{')
            {
                NSDictionary* parsed = [NSJSONSerialization JSONObjectWithData:[split[0] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
                NSString *preSessionId = [parsed objectForKey:@"sid"];
                
                // set session ID
                sessionId = [self getSIDFromServerCookie:preSessionId];
                if (sessionId) {
                    NSLog(@"New sessionID set: %@", sessionId);
                    
                    [self sendMessage:sessionId ofType:ResponderTypeSystem];
                    // save new session cookie
                    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
                    [defaults setObject:sessionId forKey:kSessionIDKey];
                    [defaults synchronize];
                }
                else{
                    sessionId = [self getSIDFromServerCookie:preSessionId];
                    NSLog(@"Not New sessionID set: %@", sessionId);
                }
                
            }else{
                NSLog(@"The split is more than 2");
            }
            return;
        

        }
        
        ResponderType type = [split[0] characterAtIndex:0];
        NSString *content = split[1];
        
        // parse responders
        switch (type) {
            case ResponderTypeEvent: {
                NSError *error;
                NSDictionary *data = [NSJSONSerialization JSONObjectWithData:[content dataUsingEncoding:NSUTF8StringEncoding] options:0 error:&error];
                if (error) {
                    NSLog(@"Error parsing event data: %@ | %@", content, error);
                    return;
                }
                
                NSLog(@"Event received is %@",data);
                
                NSString *channel = data[@"e"];
                NSArray *results = data[@"p"];
                NSArray *callbackArray = bindCallbacks[channel];
                if ([results isKindOfClass:[NSArray class]] && callbackArray) {
                    for (NSInteger i = 0; i < callbackArray.count; i++) {
                        StreamCallback callback = (StreamCallback)callbackArray[i];
                        callback(results);
                    }
                    
                }
                
                break;
            }
                
            case ResponderTypeRPC: {
                NSError *error;
                NSDictionary *data = [NSJSONSerialization JSONObjectWithData:[content dataUsingEncoding:NSUTF8StringEncoding] options:0 error:&error];
                if (error) {
                    NSLog(@"Error parsing RPC data: %@ | %@", content, error);
                    return;
                }
                
                NSNumber *rid = data[@"id"];
                NSArray *results = data[@"p"];
                NSDictionary *err = data[@"e"];
                NSLog(@"Got response for RPC call %@", rid);
                if (err) {
                    NSLog(@"RPC call %@ error: %@", rid, err);
                    break;
                }
                
                // handle RPC call
                StreamCallback callback = rpcCallbacks[rid];
                if ([results isKindOfClass:[NSArray class]] && callback) {
                    callback(results);
                }
                
                // since RPC calls are a one-time deal, we want to remove the callback once finished
                [rpcCallbacks removeObjectForKey:rid];
                
                break;
            }
                
            case ResponderTypeSystem: {
                // if responder type is not equal to standard OK message,
                // then it must be a new sessionId
                if (![content isEqualToString:@"OK"]) {
                    // set session ID
                    sessionId = [self getSIDFromServerCookie:content];
                    if (sessionId) {
                        NSLog(@"New sessionID set: %@", sessionId);
                        
                        // save new session cookie
                        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
                        [defaults setObject:sessionId forKey:kSessionIDKey];
                        [defaults synchronize];
                    }
                }
                break;
            }
                
            default:
                NSLog(@"Undefined responder type: %C", (unichar)type);
                break;
        }
    }
    @catch (NSException *e) {
        NSLog(@"Stream: Exception on socket message: %@, %@", message, e);
    }
}

- (void)didDisconnect {
    if ([self.delegate respondsToSelector:@selector(streamDidConnect:)]) {
        [self.delegate streamDidDisconnect:self];
    }
}

- (void)didReconnect {
    // send sessionID over to the server
    if (sessionId) {
        [self sendMessage:sessionId ofType:ResponderTypeSystem];
    }
    else {
        [self sendMessage:@"null" ofType:ResponderTypeSystem];
    }
    
    if ([self.delegate respondsToSelector:@selector(streamDidReconnect:)]) {
        [self.delegate streamDidReconnect:self];
    }
}

- (void)didConnect {
    // send sessionID over to the server
    if (sessionId) {
        [self sendMessage:sessionId ofType:ResponderTypeSystem];
    }
    else {
        [self sendMessage:@"null" ofType:ResponderTypeSystem];
    }
    
    if ([self.delegate respondsToSelector:@selector(streamDidConnect:)]) {
        [self.delegate streamDidConnect:self];
    }
}

- (void)sendMessage:(NSString *)message ofType:(ResponderType)type
{
    NSString *msg = [NSString stringWithFormat:@"%C|%@", (unichar)type, message];
    [socket sendMessage:msg];
}


#pragma mark public functions

- (void)connectToServer {
    [socket connectToServer];
}

- (void)disconnect {
    [socket disconnect];
}

- (void)bind:(NSString *)channel withCallback:(StreamCallback)callback
{
    // add callback to dictionary
    NSMutableArray *callbackArray = bindCallbacks[channel];
    if (!callbackArray) {
        callbackArray = [[NSMutableArray alloc] init];
    }
    [callbackArray addObject:callback];
    bindCallbacks[channel] = callbackArray;
   
}

- (void)rpc:(NSString *)method withParameters:(NSArray *)params andCallback:(StreamCallback)callback
{
    // build data and call server
    NSDictionary *json = @{
        @"id": [NSNumber numberWithInteger:rpcId],
        @"m": method,
        @"p": params ?: @[],
    };
    NSError *error;
    NSData *data = [NSJSONSerialization dataWithJSONObject:json options:0 error:&error];
    NSString *message = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (error) {
        NSLog(@"Error compiling JSON: %@", json);
        return;
    }
    [self sendMessage:message ofType:ResponderTypeRPC];
    
    // add callback to dictionary, with rpcId as key
    if (callback) {
        rpcCallbacks[[NSNumber numberWithInteger:rpcId]] = callback;
    }
    
    // lastly, increment rpcId for next call
    rpcId++;
}

@end
