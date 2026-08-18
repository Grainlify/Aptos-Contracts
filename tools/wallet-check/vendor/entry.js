// Only what the page uses. Bundled locally so the page has no CDN dependency,
// no version resolution at load time, and works offline.
export {
  Aptos, AptosConfig, Network, Hex, MoveVector, Serializer, Deserializer,
  AccountAddress, AccountAuthenticator, generateSigningMessageForTransaction,
} from "@aptos-labs/ts-sdk";
