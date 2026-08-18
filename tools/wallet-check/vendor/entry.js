// Only what the page uses. Bundled locally so the page has no CDN dependency,
// no version resolution at load time, and works offline.
export {
  Aptos, AptosConfig, Network, Hex, MoveVector, Serializer, Deserializer,
  AccountAddress, AccountAuthenticator, generateSigningMessageForTransaction,
  // Needed to REBUILD an authenticator from verified bytes rather than passing
  // the wallet's own object downstream. Backpack returns a public key as
  // {type:"Buffer",data:[...]} and a refusal as {status:"Rejected"}; neither has
  // the methods the submit path calls. See senderAuthenticator() in index.html.
  Ed25519PublicKey, Ed25519Signature, AnyPublicKey, AnySignature,
  AccountAuthenticatorEd25519, AccountAuthenticatorSingleKey,
} from "@aptos-labs/ts-sdk";
