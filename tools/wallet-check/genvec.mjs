// Produce golden vectors for the Go BCS encoder, from the TS SDK.
//
// The oracle is a DIFFERENT implementation: if Go reproduces these bytes, the
// hand-written struct layout matches the reference one for this shape.
import { Aptos, AptosConfig, Network, AccountAddress, MoveVector, U64, generateSigningMessageForTransaction }
  from "@aptos-labs/ts-sdk";

const aptos = new Aptos(new AptosConfig({ network: Network.TESTNET }));
const MOD    = "0x1b419fe2b8c2a694eda8398af4bb6f6980915f9e3ed856b3b0fb4f26597f22c9";
const ESCROW = "0xdd4fa63ec44e4726cd7d1118596866cd0c5d4cd4d3fcc9762a42261872795f45";
const SENDER = "0xd46acd056131049197eeeb3a784940a3104ebed923dacfbc013898756b9004dd";
const IDENT  = "0x" + "33".repeat(32);
// SIX proof elements: the production shape. Milestone 1 had zero.
const PROOF  = [1,2,3,4,5,6].map(i => "0x" + i.toString(16).padStart(2,"0").repeat(32));
const hex = (u8) => "0x" + Buffer.from(u8).toString("hex");

for (const [name, feePayer] of [["zero_address", "0x0"], ["named_payer", MOD]]) {
  const txn = await aptos.transaction.build.simple({
    sender: SENDER,
    withFeePayer: true,
    data: {
      function: `${MOD}::escrow::claim`,
      // TYPED explicitly. Passing hex STRINGS makes the builder encode them as
      // Move strings ("0x3333…" as ASCII) rather than vector<u8>, which produced
      // a wrong vector on the first attempt - caught because the Go encoder
      // disagreed and the real milestone transaction sided with Go.
      functionArguments: [
        AccountAddress.from(ESCROW),
        MoveVector.U8(Uint8Array.from(Buffer.from(IDENT.slice(2), "hex"))),
        new U64(1000000n),
        new MoveVector(PROOF.map(p => MoveVector.U8(Uint8Array.from(Buffer.from(p.slice(2), "hex"))))),
      ],
    },
    options: {
      // A MULTI-BYTE sequence number: 0 is one byte and would not catch a u64
      // endianness error.
      accountSequenceNumber: 258,
      maxGasAmount: 20000,
      gasUnitPrice: 100,
      expireTimestamp: 1787028364,
    },
  });
  txn.feePayerAddress = AccountAddress.from(feePayer);
  const msg = generateSigningMessageForTransaction(txn);
  console.log(JSON.stringify({ name, feePayer, proof: PROOF, ident: IDENT,
    sender: SENDER, seq: 258, maxGas: 20000, price: 100, expires: 1787028364,
    module: MOD, escrow: ESCROW, amount: "1000000", message: hex(msg) }));
}
