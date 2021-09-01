# Wrapper (ICPunks):

The `wrap` call will start the wrapping process but indicating the intention to create a wrapper, validating the ownership of the original asset and then creating a temporary wrapper to store for the time being.

**This call needs to be made by the current owner of the original asset**

```
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
```
The `mint` call occurs after the initial `wrap` call, which is followed by transferring the original asset to the Wrapper canister. We can the complete the process by "minting" the wrapped token, where we correct check that the owner of the original asset is infact the Wrapper canister.

**This call can be made by anyone, and will transfer the minted token to the user stored in temporary storage (from step 1).**
```
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
```

Finally, to unwrap, we simply call the `unwrap` function. This verifies ownership and, sends the original asset to the user, and burns the wrapped token.

**This call needs to be made by the current owner of the wrapped token**
```
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
```
