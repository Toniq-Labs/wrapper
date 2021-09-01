import Cycles "mo:base/ExperimentalCycles";
import HashMap "mo:base/HashMap";
import Nat64 "mo:base/Nat64";
import Nat32 "mo:base/Nat32";
import Principal "mo:base/Principal";
import Result "mo:base/Result";
import Iter "mo:base/Iter";
import Blob "mo:base/Blob";
import Text "mo:base/Text";
import Time "mo:base/Time";
import Array "mo:base/Array";
import Option "mo:base/Option";

import AID "../motoko/util/AccountIdentifier";
import ExtCore "../motoko/ext/Core";
import ExtCommon "../motoko/ext/Common";
import ExtAllowance "../motoko/ext/Allowance";
import ExtNonFungible "../motoko/ext/NonFungible";

shared (install) actor class nft_canister() = this {
  
  // Types
  type Time = Time.Time;
  type AccountIdentifier = ExtCore.AccountIdentifier;
  type SubAccount = ExtCore.SubAccount;
  type User = ExtCore.User;
  type Balance = ExtCore.Balance;
  type TokenIdentifier = ExtCore.TokenIdentifier;
  type TokenIndex  = ExtCore.TokenIndex ;
  type Extension = ExtCore.Extension;
  type CommonError = ExtCore.CommonError;
  type BalanceRequest = ExtCore.BalanceRequest;
  type BalanceResponse = ExtCore.BalanceResponse;
  type TransferRequest = ExtCore.TransferRequest;
  type TransferResponse = ExtCore.TransferResponse;
  type AllowanceRequest = ExtAllowance.AllowanceRequest;
  type ApproveRequest = ExtAllowance.ApproveRequest;
  type Metadata = ExtCommon.Metadata;
  type NotifyService = ExtCore.NotifyService;
  private let EXTENSIONS : [Extension] = ["@ext/common", "@ext/nonfungible"];
  
  //State work
  private stable var _registryState : [(TokenIndex, AccountIdentifier)] = [];
  private stable var _toWrapState : [(TokenIndex, Principal)] = [];
	private stable var _tokenMetadataState : [(TokenIndex, Metadata)] = [];
  private stable var _ownersState : [(AccountIdentifier, [TokenIndex])] = [];
  
  
  private var _registry : HashMap.HashMap<TokenIndex, AccountIdentifier> = HashMap.fromIter(_registryState.vals(), 0, ExtCore.TokenIndex.equal, ExtCore.TokenIndex.hash);
  private var _toWrap : HashMap.HashMap<TokenIndex, Principal> = HashMap.fromIter(_toWrapState.vals(), 0, ExtCore.TokenIndex.equal, ExtCore.TokenIndex.hash);
  private var _tokenMetadata : HashMap.HashMap<TokenIndex, Metadata> = HashMap.fromIter(_tokenMetadataState.vals(), 0, ExtCore.TokenIndex.equal, ExtCore.TokenIndex.hash);
	private var _owners : HashMap.HashMap<AccountIdentifier, [TokenIndex]> = HashMap.fromIter(_ownersState.vals(), 0, AID.equal, AID.hash);

  private stable var _supply : Balance  = 0;
  private stable var _canisterId : Text = "";
  
  let ICPUNK = actor "qcg3w-tyaaa-aaaah-qakea-cai" : actor { 
    owner_of : shared query Nat -> async Principal; 
    transfer_to : shared (Principal, Nat) -> async Bool;
  };
  
  //Wrapper
  public shared(msg) func wrap(tokenid : TokenIdentifier) : async Bool {
    if (ExtCore.TokenIdentifier.isPrincipal(tokenid, Principal.fromActor(ICPUNK)) == false) {
			return false;
		};
		let token = ExtCore.TokenIdentifier.getIndex(tokenid);
    if (Option.isSome(_registry.get(token))) {
			return false;
    };
    let owner = await ICPUNK.owner_of(Nat32.toNat(token));
    if (Option.isSome(_registry.get(token))) {
			return false;
    };
    if (Principal.equal(owner, msg.caller)) {
      _toWrap.put(token, msg.caller);
      return true;
    } else {
      return false;
    };
  };
  public shared(msg) func unwrap(tokenid : TokenIdentifier, subaccount : ?SubAccount) : async Bool {
    if (ExtCore.TokenIdentifier.isPrincipal(tokenid, Principal.fromActor(this)) == false) {
			return false;
		};
		let token = ExtCore.TokenIdentifier.getIndex(tokenid);
    let spender = AID.fromPrincipal(msg.caller, subaccount);
    switch(_registry.get(token)) {
      case(?owner) {
				if(AID.equal(owner, spender) == false) {
					return false;
				};
        _removeTokenFromUser(token);
        _tokenMetadata.delete(token);
        _registry.delete(token);
        ignore(await ICPUNK.transfer_to(msg.caller, Nat32.toNat(token)));
        return true;
      };
      case(_) return false;
    };
  };
  public shared(msg) func mint(tokenid : TokenIdentifier) : async Bool {
    if (ExtCore.TokenIdentifier.isPrincipal(tokenid, Principal.fromActor(ICPUNK)) == false) {
			return false;
		};
		let token = ExtCore.TokenIdentifier.getIndex(tokenid);
    let owner = await ICPUNK.owner_of(Nat32.toNat(token));
    switch(_toWrap.get(token)) {
      case(?p) {
        if (Principal.equal(owner, Principal.fromActor(this))) {
          _transferTokenToUser(token, AID.fromPrincipal(p, null));
          let md : Metadata = #nonfungible({
            metadata = ?Blob.fromArray([0]);
          }); 
          _tokenMetadata.put(token, md);
          _toWrap.delete(token);
          return true;
        } else {
          return false;
        };
      };
      case(_) {
        _transferTokenToUser(token, AID.fromPrincipal(msg.caller, null));
        let md : Metadata = #nonfungible({
          metadata = ?Blob.fromArray([0]);
        }); 
        _tokenMetadata.put(token, md);
        return true;
      };
    };
  };
  public query func getOutstanding() : async Nat {
    _toWrap.size();
  };
  public shared(msg) func mintOutstanding() : async Nat {
    var count : Nat = 0;
    for ((token, p) in _toWrap.entries()){
      let owner = await ICPUNK.owner_of(Nat32.toNat(token));
      if (Principal.equal(owner, Principal.fromActor(this))) {
        _transferTokenToUser(token, AID.fromPrincipal(p, null));
        let md : Metadata = #nonfungible({
          metadata = ?Blob.fromArray([0]);
        }); 
        _tokenMetadata.put(token, md);
        _toWrap.delete(token);
        count += 1;
      }
    };
    count;
  };
  
  
  //State functions
  system func preupgrade() {
    _registryState := Iter.toArray(_registry.entries());
    _toWrapState := Iter.toArray(_toWrap.entries());
    _tokenMetadataState := Iter.toArray(_tokenMetadata.entries());
    _ownersState := Iter.toArray(_owners.entries());
  };
  system func postupgrade() {
    _registryState := [];
    _toWrapState := [];
    _tokenMetadataState := [];
    _ownersState := [];
  };
  
 //Marketplace
  
  //Standard Token
  public shared(msg) func transfer(request: TransferRequest) : async TransferResponse {
    if (request.amount != 1) {
			return #err(#Other("Must use amount of 1"));
		};
		if (ExtCore.TokenIdentifier.isPrincipal(request.token, Principal.fromActor(this)) == false) {
			return #err(#InvalidToken(request.token));
		};
		let token = ExtCore.TokenIdentifier.getIndex(request.token);
    if (Option.isSome(_tokenListing.get(token))) {
			return #err(#Other("This token is currently listed for sale!"));
    };
    let owner = ExtCore.User.toAID(request.from);
    let spender = AID.fromPrincipal(msg.caller, request.subaccount);
    let receiver = ExtCore.User.toAID(request.to);
		if (AID.equal(owner, spender) == false) {
      return #err(#Unauthorized(spender));
    };
    switch (_registry.get(token)) {
      case (?token_owner) {
				if(AID.equal(owner, token_owner) == false) {
					return #err(#Unauthorized(owner));
				};
        if (request.notify) {
          switch(ExtCore.User.toPrincipal(request.to)) {
            case (?canisterId) {
              //Do this to avoid atomicity issue
              _removeTokenFromUser(token);
              let notifier : NotifyService = actor(Principal.toText(canisterId));
              switch(await notifier.tokenTransferNotification(request.token, request.from, request.amount, request.memo)) {
                case (?balance) {
                  if (balance == 1) {
                    _transferTokenToUser(token, receiver);
                    return #ok(request.amount);
                  } else {
                    //Refund
                    _transferTokenToUser(token, owner);
                    return #err(#Rejected);
                  };
                };
                case (_) {
                  //Refund
                  _transferTokenToUser(token, owner);
                  return #err(#Rejected);
                };
              };
            };
            case (_) {
              return #err(#CannotNotify(receiver));
            }
          };
        } else {
          _transferTokenToUser(token, receiver);
          return #ok(request.amount);
        };
      };
      case (_) {
        return #err(#InvalidToken(request.token));
      };
    };
  };
  public query func extensions() : async [Extension] {
    EXTENSIONS;
  };
  public query func balance(request : BalanceRequest) : async BalanceResponse {
		if (ExtCore.TokenIdentifier.isPrincipal(request.token, Principal.fromActor(this)) == false) {
			return #err(#InvalidToken(request.token));
		};
		let token = ExtCore.TokenIdentifier.getIndex(request.token);
    let aid = ExtCore.User.toAID(request.user);
    switch (_registry.get(token)) {
      case (?token_owner) {
				if (AID.equal(aid, token_owner) == true) {
					return #ok(1);
				} else {					
					return #ok(0);
				};
      };
      case (_) {
        return #err(#InvalidToken(request.token));
      };
    };
  };
	public query func bearer(token : TokenIdentifier) : async Result.Result<AccountIdentifier, CommonError> {
		if (ExtCore.TokenIdentifier.isPrincipal(token, Principal.fromActor(this)) == false) {
			return #err(#InvalidToken(token));
		};
		let tokenind = ExtCore.TokenIdentifier.getIndex(token);
    switch (_getBearer(tokenind)) {
      case (?token_owner) {
				return #ok(token_owner);
      };
      case (_) {
        return #err(#InvalidToken(token));
      };
    };
	};
  public query func supply(token : TokenIdentifier) : async Result.Result<Balance, CommonError> {
    #ok(_supply);
  };
  public query func getRegistry() : async [(TokenIndex, AccountIdentifier)] {
    Iter.toArray(_registry.entries());
  };
  public query func getTokens() : async [(TokenIndex, Metadata)] {
    var resp : [(TokenIndex, Metadata)] = [];
    for(e in _tokenMetadata.entries()){
      resp := Array.append(resp, [(e.0, #nonfungible({ metadata = null }))]);
    };
    resp;
  };
  public query func tokens(aid : AccountIdentifier) : async Result.Result<[TokenIndex], CommonError> {
    switch(_owners.get(aid)) {
      case(?tokens) return #ok(tokens);
      case(_) return #err(#Other("No tokens"));
    };
  };
  public query func tokens_ext(aid : AccountIdentifier) : async Result.Result<[(TokenIndex, ?Listing, ?Blob)], CommonError> {
		switch(_owners.get(aid)) {
      case(?tokens) {
        var resp : [(TokenIndex, ?Listing, ?Blob)] = [];
        for (a in tokens.vals()){
          switch(_tokenMetadata.get(a)) {
            case(?md) switch(md) {
              case(#fungible _) resp := Array.append(resp, [(a, _tokenListing.get(a), null)]);
              case(#nonfungible nmd) resp := Array.append(resp, [(a, _tokenListing.get(a), nmd.metadata)]);
            };
            case(null) resp := Array.append(resp, [(a, _tokenListing.get(a), null)]);
          };
        };
        return #ok(resp);
      };
      case(_) return #err(#Other("No tokens"));
    };
	};
  public query func metadata(token : TokenIdentifier) : async Result.Result<Metadata, CommonError> {
    if (ExtCore.TokenIdentifier.isPrincipal(token, Principal.fromActor(this)) == false) {
			return #err(#InvalidToken(token));
		};
		let tokenind = ExtCore.TokenIdentifier.getIndex(token);
    switch (_tokenMetadata.get(tokenind)) {
      case (?token_metadata) {
				return #ok(token_metadata);
      };
      case (_) {
        return #err(#InvalidToken(token));
      };
    };
  };
  public query func details(token : TokenIdentifier) : async Result.Result<(AccountIdentifier, ?Listing), CommonError> {
		if (ExtCore.TokenIdentifier.isPrincipal(token, Principal.fromActor(this)) == false) {
			return #err(#InvalidToken(token));
		};
		let tokenind = ExtCore.TokenIdentifier.getIndex(token);
    switch (_getBearer(tokenind)) {
      case (?token_owner) {
				return #ok((token_owner, _tokenListing.get(tokenind)));
      };
      case (_) {
        return #err(#InvalidToken(token));
      };
    };
	};
  
  //HTTP
  type HeaderField = (Text, Text);
  type HttpResponse = {
    status_code: Nat16;
    headers: [HeaderField];
    body: Blob;
  };
  type HttpRequest = {
    method : Text;
    url : Text;
    headers : [HeaderField];
    body : Blob;
  };
  let NOT_FOUND : HttpResponse = {status_code = 404; headers = []; body = Blob.fromArray([]); streaming_strategy = null};
  let BAD_REQUEST : HttpResponse = {status_code = 400; headers = []; body = Blob.fromArray([]); streaming_strategy = null};
  
  public query func http_request(request : HttpRequest) : async HttpResponse {
    let path = Iter.toArray(Text.tokens(request.url, #text("/")));
    switch(_getTokenData(_getParam(request.url, "tokenid"))) {
      case (?metadata) {
        return {
          status_code = 200;
          headers = [("content-type", "image/jpeg")];
          body = metadata
        }
      };
      case (_) {
        return {
          status_code = 200;
          headers = [("content-type", "text/plain")];
          body = Text.encodeUtf8 (
            "Cycle Balance:                            ~" # debug_show (Cycles.balance()/1000000000000) # "T\n" #
            "Wrapped NFTs:                             " # debug_show (_registry.size()) # "\n" #
          )
        };
      };
    };
  };
  func _getTokenData(tokenid : ?Text) : ?Blob {
    switch (tokenid) {
      case (?token) {
        if (ExtCore.TokenIdentifier.isPrincipal(token, Principal.fromActor(this)) == false) {
          return null;
        };
        let tokenind = ExtCore.TokenIdentifier.getIndex(token);
        switch (_tokenMetadata.get(tokenind)) {
          case (?token_metadata) {
            switch(token_metadata) {
              case (#fungible data) return null;
              case (#nonfungible data) return data.metadata;
            };
          };
          case (_) {
            return null;
          };
        };
				return null;
      };
      case (_) {
        return null;
      };
    };
  };
  func _getParam(url : Text, param : Text) : ?Text {
    var _s : Text = url;
    Iter.iterate<Text>(Text.split(_s, #text("/")), func(x, _i) {
      _s := x;
    });
    Iter.iterate<Text>(Text.split(_s, #text("?")), func(x, _i) {
      if (_i == 1) _s := x;
    });
    var t : ?Text = null;
    var found : Bool = false;
    Iter.iterate<Text>(Text.split(_s, #text("&")), func(x, _i) {
      Iter.iterate<Text>(Text.split(x, #text("=")), func(y, _ii) {
        if (_ii == 0) {
          if (Text.equal(y, param)) found := true;
        } else if (found == true) t := ?y;
      });
    });
    return t;
  };
  
  //Internal cycle management - good general case
  public func acceptCycles() : async () {
    let available = Cycles.available();
    let accepted = Cycles.accept(available);
    assert (accepted == available);
  };
  public query func availableCycles() : async Nat {
    return Cycles.balance();
  };
  
  //Private
  func _removeTokenFromUser(tindex : TokenIndex) : () {
    let owner : ?AccountIdentifier = _getBearer(tindex);
    _registry.delete(tindex);
    switch(owner){
      case (?o) _removeFromUserTokens(tindex, o);
      case (_) {};
    };
  };
  func _transferTokenToUser(tindex : TokenIndex, receiver : AccountIdentifier) : () {
    let owner : ?AccountIdentifier = _getBearer(tindex);
    _registry.put(tindex, receiver);
    switch(owner){
      case (?o) _removeFromUserTokens(tindex, o);
      case (_) {};
    };
    _addToUserTokens(tindex, receiver);
  };
  func _removeFromUserTokens(tindex : TokenIndex, owner : AccountIdentifier) : () {
    switch(_owners.get(owner)) {
      case(?ownersTokens) _owners.put(owner, Array.filter(ownersTokens, func (a : TokenIndex) : Bool { (a != tindex) }));
      case(_) ();
    };
  };
  func _addToUserTokens(tindex : TokenIndex, receiver : AccountIdentifier) : () {
    let ownersTokensNew : [TokenIndex] = switch(_owners.get(receiver)) {
      case(?ownersTokens) Array.append(ownersTokens, [tindex]);
      case(_) [tindex];
    };
    _owners.put(receiver, ownersTokensNew);
  };
  func _getBearer(tindex : TokenIndex) : ?AccountIdentifier {
    _registry.get(tindex);
  };
}