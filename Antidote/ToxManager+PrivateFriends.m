//
//  ToxManager+PrivateFriends.m
//  Antidote
//
//  Created by Dmitry Vorobyov on 15.08.14.
//  Copyright (c) 2014 dvor. All rights reserved.
//

#import "ToxManager+PrivateFriends.h"
#import "ToxManager+Private.h"
#import "ToxFriend+Private.h"
#import "ToxFunctions.h"
#import "UserInfoManager.h"
#import "EventsManager.h"
#import "AppDelegate.h"

void friendRequestCallback(Tox *tox, const uint8_t * public_key, const uint8_t * data, uint16_t length, void *userdata);
void nameChangeCallback(Tox *tox, int32_t friendnumber, const uint8_t *newname, uint16_t length, void *userdata);
void statusMessageCallback(Tox *tox, int32_t friendnumber, const uint8_t *newstatus, uint16_t length, void *userdata);
void userStatusCallback(Tox *tox, int32_t friendnumber, uint8_t status, void *userdata);
void typingChangeCallback(Tox *tox, int32_t friendnumber, uint8_t isTyping, void *userdata);
void connectionStatusCallback(Tox *tox, int32_t friendnumber, uint8_t status, void *userdata);

@implementation ToxManager (PrivateFriends)

#pragma mark -  Public

- (void)qRegisterFriendsCallbacks
{
    NSAssert(dispatch_get_specific(kIsOnToxManagerQueue), @"Must be on ToxManager queue");

    tox_callback_friend_request    (self.tox, friendRequestCallback,    NULL);
    tox_callback_name_change       (self.tox, nameChangeCallback,       NULL);
    tox_callback_status_message    (self.tox, statusMessageCallback,    NULL);
    tox_callback_user_status       (self.tox, userStatusCallback,       NULL);
    tox_callback_typing_change     (self.tox, typingChangeCallback,     NULL);
    tox_callback_connection_status (self.tox, connectionStatusCallback, NULL);
}

- (void)qLoadFriendsAndCreateContainer
{
    NSAssert(dispatch_get_specific(kIsOnToxManagerQueue), @"Must be on ToxManager queue");

    uint32_t friendsCount = tox_count_friendlist(self.tox);
    uint32_t listSize = friendsCount * sizeof(int32_t);

    int32_t *friendsList = malloc(listSize);

    tox_get_friendlist(self.tox, friendsList, listSize);

    NSMutableArray *friendsArray = [NSMutableArray new];

    for (NSUInteger index = 0; index < friendsCount; index++) {
        int32_t friendId = friendsList[index];

        [friendsArray addObject:[self qCreateFriendWithId:friendId]];
    }

    self.friendsContainer = [[ToxFriendsContainer alloc] initWithFriendsArray:[friendsArray copy]];

    free(friendsList);
}


- (void)qSendFriendRequestWithAddress:(NSString *)addressString message:(NSString *)messageString
{
    NSAssert(dispatch_get_specific(kIsOnToxManagerQueue), @"Must be on ToxManager queue");

    if (! messageString.length) {
        messageString = NSLocalizedString(@"Please, add me", @"Tox empty message");
    }

    uint8_t *address = [ToxFunctions hexStringToBin:addressString];
    const char *message = [messageString cStringUsingEncoding:NSUTF8StringEncoding];

    int32_t result = tox_add_friend(
            self.tox,
            address,
            (const uint8_t *)message,
            [messageString lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);

    free(address);

    if (result > -1) {
        [self qSaveTox];

        [self.friendsContainer private_addFriend:[self qCreateFriendWithId:result]];
    }
    else {

    }
}

- (void)qMarkAllFriendRequestsAsSeen
{
    NSAssert(dispatch_get_specific(kIsOnToxManagerQueue), @"Must be on ToxManager queue");

    [self.friendsContainer private_markAllFriendRequestsAsSeen];
}

- (void)qApproveFriendRequest:(ToxFriendRequest *)request wasError:(BOOL *)wasError
{
    NSAssert(dispatch_get_specific(kIsOnToxManagerQueue), @"Must be on ToxManager queue");

    uint8_t *clientId = [ToxFunctions hexStringToBin:request.clientId];
    int32_t friendId = tox_add_friend_norequest(self.tox, clientId);
    free(clientId);

    if (friendId == -1) {
        if (wasError) {
            *wasError = YES;
        }
    }
    else {
        [self qSaveTox];

        [self.friendsContainer private_removeFriendRequest:request];
        [self.friendsContainer private_addFriend:[self qCreateFriendWithId:friendId]];
    }
}

- (void)qRemoveFriendRequest:(ToxFriendRequest *)request
{
    NSAssert(dispatch_get_specific(kIsOnToxManagerQueue), @"Must be on ToxManager queue");

    if (! request) {
        return;
    }

    [self.friendsContainer private_removeFriendRequest:request];
}

- (void)qRemoveFriend:(ToxFriend *)friend
{
    NSAssert(dispatch_get_specific(kIsOnToxManagerQueue), @"Must be on ToxManager queue");

    if (! friend) {
        return;
    }

    tox_del_friend(self.tox, friend.id);
    [self qSaveTox];

    [self.friendsContainer private_removeFriend:friend];
}

- (void)qChangeAssociatedNameTo:(NSString *)name forFriend:(ToxFriend *)friendToChange
{
    NSAssert(dispatch_get_specific(kIsOnToxManagerQueue), @"Must be on ToxManager queue");

    [self.friendsContainer private_updateFriendWithId:friendToChange.id updateBlock:^(ToxFriend *friend) {
        if (! friend.clientId) {
            return;
        }

        friend.associatedName = name;

        if (name.length) {
            NSMutableDictionary *names = [NSMutableDictionary dictionaryWithDictionary:
                [UserInfoManager sharedInstance].uAssociatedNames];

            names[friend.clientId] = name;

            [UserInfoManager sharedInstance].uAssociatedNames = [names copy];
        }
        else {
            [[ToxManager sharedInstance] qMaybeCreateAssociatedNameForFriend:friend];
        }
    }];
}

#pragma mark -  Private

- (ToxFriend *)qCreateFriendWithId:(int32_t)friendId
{
    NSAssert(dispatch_get_specific(kIsOnToxManagerQueue), @"Must be on ToxManager queue");

    if (! tox_friend_exists(self.tox, friendId)) {
        return nil;
    }

    ToxFriend *friend = [ToxFriend new];
    friend.id = friendId;
    friend.status = ToxFriendStatusOffline;

    {
        uint8_t *clientId = malloc(TOX_CLIENT_ID_SIZE);

        int result = tox_get_client_id(self.tox, friendId, clientId);

        if (result == 0) {
            friend.clientId = [ToxFunctions clientIdToString:clientId];
            free(clientId);
        }
    }

    {
        uint8_t *name = malloc(TOX_MAX_NAME_LENGTH);
        int length = tox_get_name(self.tox, friendId, name);

        if (length > 0) {
            friend.realName = [NSString stringWithCString:(const char*)name encoding:NSUTF8StringEncoding];
            free(name);
        }
    }

    {
        uint64_t lastOnline = tox_get_last_online(self.tox, friendId);

        if (lastOnline > 0) {
            friend.lastSeenOnline = [NSDate dateWithTimeIntervalSince1970:lastOnline];
        }
    }

    friend.isTyping = tox_get_is_typing(self.tox, friendId);

    {
        if (friend.clientId) {
            NSDictionary *names = [UserInfoManager sharedInstance].uAssociatedNames;

            friend.associatedName = names[friend.clientId];
        }
    }

    [self qMaybeCreateAssociatedNameForFriend:friend];

    return friend;
}

- (void)qMaybeCreateAssociatedNameForFriend:(ToxFriend *)friend
{
    NSAssert(dispatch_get_specific(kIsOnToxManagerQueue), @"Must be on ToxManager queue");

    if (friend.associatedName.length) {
        return;
    }

    if (! friend.realName) {
        return;
    }

    friend.associatedName = friend.realName;

    if (! friend.clientId) {
        return;
    }

    NSMutableDictionary *names = [NSMutableDictionary dictionaryWithDictionary:
        [UserInfoManager sharedInstance].uAssociatedNames];

    names[friend.clientId] = friend.realName;

    [UserInfoManager sharedInstance].uAssociatedNames = [names copy];
}

@end

#pragma mark -  C functions

void friendRequestCallback(Tox *tox, const uint8_t * publicKey, const uint8_t * data, uint16_t length, void *userdata)
{
    NSLog(@"ToxManager: friendRequestCallback, publicKey %s", publicKey);

    NSString *key = [ToxFunctions publicKeyToString:(uint8_t *)publicKey];
    NSString *message = [[NSString alloc] initWithBytes:data length:length encoding:NSUTF8StringEncoding];

    ToxFriendRequest *request = [ToxFriendRequest friendRequestWithPublicKey:key message:message];

    [[ToxManager sharedInstance].friendsContainer private_addFriendRequest:request];

    EventObject *object = [EventObject objectWithType:EventObjectTypeFriendRequest
                                                image:nil
                                               object:request];
    [[EventsManager sharedInstance] addObject:object];

    dispatch_async(dispatch_get_main_queue(), ^{
        AppDelegate *delegate = (AppDelegate *)[UIApplication sharedApplication].delegate;
        [delegate updateBadgeForTab:AppDelegateTabIndexFriends];
    });
}

void nameChangeCallback(Tox *tox, int32_t friendnumber, const uint8_t *newname, uint16_t length, void *userdata)
{
    NSLog(@"ToxManager: nameChangeCallback %d %s", friendnumber, newname);

    [[ToxManager sharedInstance].friendsContainer private_updateFriendWithId:friendnumber updateBlock:^(ToxFriend *friend) {
        friend.realName = [NSString stringWithCString:(const char*)newname encoding:NSUTF8StringEncoding];

        [[ToxManager sharedInstance] qMaybeCreateAssociatedNameForFriend:friend];
    }];
}

void statusMessageCallback(Tox *tox, int32_t friendnumber, const uint8_t *newstatus, uint16_t length, void *userdata)
{
    NSLog(@"ToxManager: statusMessageCallback %d %s", friendnumber, newstatus);

    [[ToxManager sharedInstance].friendsContainer private_updateFriendWithId:friendnumber updateBlock:^(ToxFriend *friend) {
        friend.statusMessage = [NSString stringWithCString:(const char*)newstatus encoding:NSUTF8StringEncoding];
    }];
}

void userStatusCallback(Tox *tox, int32_t friendnumber, uint8_t status, void *userdata)
{
    NSLog(@"ToxManager: userStatusCallback %d %d", friendnumber, status);

    [[ToxManager sharedInstance].friendsContainer private_updateFriendWithId:friendnumber updateBlock:^(ToxFriend *friend) {
        if (status == TOX_USERSTATUS_NONE) {
            friend.status = ToxFriendStatusOnline;
        }
        else if (status == TOX_USERSTATUS_AWAY) {
            friend.status = ToxFriendStatusAway;
        }
        else if (status == TOX_USERSTATUS_BUSY) {
            friend.status = ToxFriendStatusBusy;
        }
        else if (status == TOX_USERSTATUS_INVALID) {
            friend.status = ToxFriendStatusOffline;
        }
    }];
}

void typingChangeCallback(Tox *tox, int32_t friendnumber, uint8_t isTyping, void *userdata)
{
    NSLog(@"ToxManager: typingChangeCallback %d %d", friendnumber, isTyping);

    [[ToxManager sharedInstance].friendsContainer private_updateFriendWithId:friendnumber updateBlock:^(ToxFriend *friend) {
        friend.isTyping = (isTyping == 1);
    }];
}

void connectionStatusCallback(Tox *tox, int32_t friendnumber, uint8_t status, void *userdata)
{
    NSLog(@"ToxManager: connectionStatusCallback %d %d", friendnumber, status);

    [[ToxManager sharedInstance].friendsContainer private_updateFriendWithId:friendnumber updateBlock:^(ToxFriend *friend) {
        if (status == 0) {
            friend.status = ToxFriendStatusOffline;
        }
    }];

    [[ToxManager sharedInstance] qSaveTox];
}

