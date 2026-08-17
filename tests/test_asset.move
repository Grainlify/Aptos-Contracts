#[test_only]
/// A minimal fungible asset for tests, at USDC's 6 decimals.
///
/// Deliberately a plain fungible asset with no registered hooks, which is worth
/// stating because it is a limitation of these tests rather than a choice about
/// the contract. `dispatchable_fungible_asset` is the superset API: it honours
/// hooks where they exist and falls through to the default behaviour where they
/// do not. So exercising the escrow against a hookless asset proves the calls
/// are well-formed and proves nothing about hook interaction.
///
/// Real USDC on Aptos *is* dispatchable, so the remaining risk is a hook that
/// rejects a transfer - a deny-listed address, or a paused asset. That is a
/// testnet rehearsal concern, not something a unit test against a token we mint
/// ourselves can reach.
module grainlify_payout::test_asset {
    use std::option;
    use std::signer;
    use std::string;

    use aptos_framework::dispatchable_fungible_asset;
    use aptos_framework::fungible_asset::{Self, Metadata, MintRef};
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store;

    use grainlify_payout::escrow;

    struct Caps has key {
        mint_ref: MintRef,
    }

    /// Create the asset, holding its mint capability under the creator.
    public fun create(creator: &signer): Object<Metadata> {
        let ctor = object::create_named_object(creator, b"GRAINLIFY_TEST_USD");
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &ctor,
            option::none(),
            string::utf8(b"Grainlify Test USD"),
            string::utf8(b"gtUSD"),
            6, // USDC's precision, so amounts in tests read as minor units
            string::utf8(b""),
            string::utf8(b""),
        );
        let mint_ref = fungible_asset::generate_mint_ref(&ctor);
        move_to(creator, Caps { mint_ref });
        object::object_from_constructor_ref<Metadata>(&ctor)
    }

    public fun mint(creator: &signer, to: address, amount: u64) acquires Caps {
        let caps = borrow_global<Caps>(signer::address_of(creator));
        let metadata = fungible_asset::mint_ref_metadata(&caps.mint_ref);
        let store = primary_fungible_store::ensure_primary_store_exists(to, metadata);
        fungible_asset::mint_to(&caps.mint_ref, store, amount);
    }

    /// Push tokens straight into another account's escrow store, bypassing any
    /// module entry point - which is exactly what a griefer can do, because
    /// dispatchable_fungible_asset::deposit takes no signer.
    public fun deposit_into(from: &signer, escrow_addr: address, amount: u64) acquires Caps {
        let caps = borrow_global<Caps>(@0xA11CE);
        let metadata = fungible_asset::mint_ref_metadata(&caps.mint_ref);
        let from_store = primary_fungible_store::ensure_primary_store_exists(
            signer::address_of(from), metadata);
        let escrow_store = escrow::escrow_store(escrow_addr);
        dispatchable_fungible_asset::transfer(from, from_store, escrow_store, amount);
    }

    public fun balance_of(owner: address, metadata: Object<Metadata>): u64 {
        primary_fungible_store::balance(owner, metadata)
    }
}
