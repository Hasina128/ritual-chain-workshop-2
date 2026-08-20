import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { network } from "hardhat";
import { getAddress, parseEther, stringToHex } from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";

const SCHEDULER = "0x56e776BAE2DD60664b69Bd5F865F1180ffB7D58B" as const;
const PURSE = "0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948" as const;
const REG = "0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F" as const;
const HTTP = "0x0000000000000000000000000000000000000801" as const;
const JQ = "0x0000000000000000000000000000000000000803" as const;
const TEE = getAddress("0x0000000000000000000000000000000000000aaa");

describe("desk walk", async function () {
  const { viem, networkHelpers } = await network.create();
  const publicClient = await viem.getPublicClient();
  const testClient = await viem.getTestClient();

  const kayAcct = privateKeyToAccount(generatePrivateKey());
  const leoAcct = privateKeyToAccount(generatePrivateKey());
  await testClient.setBalance({ address: kayAcct.address, value: parseEther("100") });
  await testClient.setBalance({ address: leoAcct.address, value: parseEther("100") });

  const kay = await viem.getWalletClient(kayAcct);
  const leo = await viem.getWalletClient(leoAcct);
  assert.ok(kay && leo, "hardhat did not return wallet clients for the ticket buyers");

  async function paint(name: string, address: `0x${string}`) {
    const d = await viem.deployContract(name);
    const code = await publicClient.getCode({ address: d.address });
    assert.ok(code && code !== "0x", `no bytecode for ${name}`);
    await testClient.setCode({ address, bytecode: code });
    const etched = await publicClient.getCode({ address });
    assert.ok(etched && etched !== "0x", `setCode failed for ${name} at ${address}`);
    return viem.getContractAt(name, address);
  }

  async function world() {
    const scheduler = await paint("StubScheduler", SCHEDULER);
    await paint("StubPurse", PURSE);
    const registry = await paint("StubRegistry", REG);
    const http = await paint("StubHttp", HTTP);
    const jq = await paint("StubJq", JQ);
    await registry.write.configure([TEE, true]);
    await http.write.tune([200, stringToHex('{"price":4100}'), ""]);
    await jq.write.set([4100n]);
    const desk = await viem.deployContract("RitualPredict", [1000n]);
    await desk.write.fundExecution([50n], { value: parseEther("1") });
    return { desk, scheduler, http };
  }

  async function mineTo(block: bigint) {
    const now = await publicClient.getBlockNumber();
    if (block > now) await networkHelpers.mine(Number(block - now));
  }

  const spec = {
    question: "ETH at least 4000 by close?",
    oracleUrl: "https://feed.example/eth",
    jsonPath: ".price",
    target: 4000n,
    comparator: 1,
    bettingSeconds: 30n,
    resolveDelaySeconds: 15n,
  } as const;

  it("clears the book: yes tickets take the full pool", async function () {
    const { desk, scheduler } = await world();
    await desk.write.createMarket([spec]);
    const id = await desk.read.marketCount();
    await desk.write.bet([id, true], { account: kay.account, value: parseEther("3") });
    await desk.write.bet([id, false], { account: leo.account, value: parseEther("1") });
    const row = await desk.read.getMarket([id]);
    await mineTo(row.resolveBlock);
    await scheduler.write.kick([row.scheduleId, 0n]);
    const done = await desk.read.getMarket([id]);
    assert.equal(done.state, 3, `expected SETTLED, got state=${done.state} outcome=${done.outcome} reason=${done.invalidReason}`);
    assert.equal(done.outcome, 1);
    assert.equal(done.observedValue, 4100n);
    const before = await publicClient.getBalance({ address: kay.account.address });
    const hash = await desk.write.claimWinnings([id], { account: kay.account });
    const rec = await publicClient.waitForTransactionReceipt({ hash });
    const after = await publicClient.getBalance({ address: kay.account.address });
    assert.equal(after + rec.gasUsed * rec.effectiveGasPrice - before, parseEther("4"));
  });

  it("voids the book after three feed misses and returns tickets", async function () {
    const { desk, scheduler, http } = await world();
    await http.write.jam([true]);
    await desk.write.createMarket([spec]);
    const id = await desk.read.marketCount();
    await desk.write.bet([id, true], { account: kay.account, value: parseEther("2") });
    const row = await desk.read.getMarket([id]);
    await mineTo(row.resolveBlock);
    await scheduler.write.kick([row.scheduleId, 0n]);
    await scheduler.write.kick([row.scheduleId, 1n]);
    await scheduler.write.kick([row.scheduleId, 2n]);
    const voided = await desk.read.getMarket([id]);
    assert.equal(voided.state, 4, `expected VOID, got state=${voided.state} outcome=${voided.outcome} attempts=${voided.attempts}`);
    assert.equal(voided.outcome, 0);
    const before = await publicClient.getBalance({ address: kay.account.address });
    const hash = await desk.write.claimRefund([id], { account: kay.account });
    const rec = await publicClient.waitForTransactionReceipt({ hash });
    const after = await publicClient.getBalance({ address: kay.account.address });
    assert.equal(after + rec.gasUsed * rec.effectiveGasPrice - before, parseEther("2"));
  });
});
