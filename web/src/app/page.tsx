"use client";

import { useEffect, useState } from "react";
import { formatEther, parseEther } from "viem";
import {
  useAccount,
  useConnect,
  useDisconnect,
  useReadContract,
} from "wagmi";
import { deskAddress, explorer, faucet, feedHint, ritual } from "@/config/chain";
import { marketAbi } from "@/abi/market";
import { COMPARATOR, DEMO, MARK, PHASE, SIDE } from "@/lib/copy";
import { useSend } from "@/hooks/useSend";

type Row = {
  id: bigint;
  creator: `0x${string}`;
  question: string;
  oracleUrl: string;
  jsonPath: string;
  target: bigint;
  comparator: number;
  closeBlock: bigint;
  resolveBlock: bigint;
  scheduleId: bigint;
  totalYes: bigint;
  totalNo: bigint;
  state: number;
  outcome: number;
  attempts: number;
  observedValue: bigint;
  invalidReason: string;
};

function ink(n?: bigint) {
  if (n === undefined) return "—";
  return `${Number(formatEther(n)).toFixed(3)} RIT`;
}

export default function DeskPage() {
  const { address, isConnected } = useAccount();
  const { connect, connectors } = useConnect();
  const { disconnect } = useDisconnect();
  const send = useSend();
  const wired = Boolean(deskAddress);

  const { data: rows, refetch } = useReadContract({
    address: deskAddress,
    abi: marketAbi,
    functionName: "getMarkets",
    query: { enabled: wired, refetchInterval: 6000 },
  });

  const { data: purse } = useReadContract({
    address: deskAddress,
    abi: marketAbi,
    functionName: "executionBalance",
    query: { enabled: wired, refetchInterval: 8000 },
  });

  const list = (rows as Row[] | undefined) ?? [];

  return (
    <div className="mx-auto max-w-4xl px-5 py-8 font-[family-name:var(--font-serif)]">
      <header className="masthead-rule py-3 text-center">
        <div className="font-[family-name:var(--font-mono)] text-[10px] tracking-[0.35em] uppercase">
          Ritual chain · desk 1979
        </div>
        <h1 className="mt-1 text-5xl tracking-tight">The Desk</h1>
        <p className="mt-2 text-sm italic opacity-80">
          Markets that file their own close. No night editor. No cron.
        </p>
        <div className="mt-3 flex justify-center gap-3 font-[family-name:var(--font-mono)] text-xs">
          {isConnected ? (
            <button className="underline" onClick={() => disconnect()}>
              {address?.slice(0, 6)}…{address?.slice(-4)}
            </button>
          ) : (
            <button
              className="underline"
              onClick={() => connectors[0] && connect({ connector: connectors[0] })}
            >
              Plug wallet
            </button>
          )}
          <a href={faucet} className="underline" target="_blank" rel="noreferrer">
            Faucet
          </a>
          <span>purse {ink(purse as bigint | undefined)}</span>
        </div>
      </header>

      {!wired && (
        <p className="mt-6 border border-[var(--ink)] px-3 py-2 text-sm">
          Set NEXT_PUBLIC_PREDICT_ADDRESS in web/.env.local after deploy.
        </p>
      )}

      <div className="mt-8 grid gap-8 md:grid-cols-2">
        <OpenForm
          ready={isConnected && wired}
          onDone={() => void refetch()}
          send={send}
        />
        <aside className="space-y-8">
          <FundBox ready={isConnected && wired} send={send} />
          <WireBox />
        </aside>
      </div>

      <section className="mt-10">
        <h2 className="font-[family-name:var(--font-mono)] text-xs tracking-[0.25em] uppercase">
          The book
        </h2>
        <div className="mt-3 space-y-5">
          {list.length === 0 && (
            <p className="italic opacity-70">The book is empty.</p>
          )}
          {list.map((r) => (
            <Ticket
              key={r.id.toString()}
              row={r}
              me={address}
              ready={isConnected && wired}
              send={send}
              onDone={() => void refetch()}
            />
          ))}
        </div>
      </section>
    </div>
  );
}

function OpenForm({
  ready,
  onDone,
  send,
}: {
  ready: boolean;
  onDone: () => void;
  send: ReturnType<typeof useSend>;
}) {
  const [q, setQ] = useState(DEMO.question);
  const [url, setUrl] = useState(feedHint);
  const [path, setPath] = useState(DEMO.jsonPath);
  const [target, setTarget] = useState(String(DEMO.target));
  const [cmp, setCmp] = useState<keyof typeof COMPARATOR>("gte");
  const [betS, setBetS] = useState(String(DEMO.bettingSeconds));
  const [delay, setDelay] = useState(String(DEMO.resolveDelaySeconds));

  const loop = /localhost|127\.0\.0\.1/i.test(url);

  return (
    <form
      className="border border-[var(--ink)] p-4"
      onSubmit={(e) => {
        e.preventDefault();
        if (!deskAddress) return;
        void send
          .send({
            address: deskAddress,
            abi: marketAbi,
            functionName: "createMarket",
            args: [
              {
                question: q,
                oracleUrl: url,
                jsonPath: path,
                target: BigInt(target || "0"),
                comparator: COMPARATOR[cmp],
                bettingSeconds: BigInt(betS || "0"),
                resolveDelaySeconds: BigInt(delay || "0"),
              },
            ],
          })
          .then(onDone)
          .catch(() => undefined);
      }}
    >
      <h2 className="font-[family-name:var(--font-mono)] text-xs tracking-[0.25em] uppercase">
        File a market
      </h2>
      <label className="mt-3 block text-xs">
        Question
        <textarea
          className="mt-1 w-full border border-[var(--rule)] bg-transparent p-2 text-sm"
          rows={2}
          value={q}
          onChange={(e) => setQ(e.target.value)}
        />
      </label>
      <label className="mt-3 block text-xs">
        Public feed URL
        <input
          className="mt-1 w-full border border-[var(--rule)] bg-transparent p-2 font-[family-name:var(--font-mono)] text-xs"
          value={url}
          onChange={(e) => setUrl(e.target.value)}
        />
      </label>
      {loop && (
        <p className="mt-1 text-xs text-[var(--no)]">
          Loopback is rejected on-chain. Tunnel first.
        </p>
      )}
      <div className="mt-3 grid grid-cols-2 gap-2 text-xs">
        <label>
          jq
          <input
            className="mt-1 w-full border border-[var(--rule)] bg-transparent p-2 font-[family-name:var(--font-mono)]"
            value={path}
            onChange={(e) => setPath(e.target.value)}
          />
        </label>
        <label>
          Target
          <input
            className="mt-1 w-full border border-[var(--rule)] bg-transparent p-2"
            type="number"
            value={target}
            onChange={(e) => setTarget(e.target.value)}
          />
        </label>
        <label>
          Rule
          <select
            className="mt-1 w-full border border-[var(--rule)] bg-[var(--paper)] p-2"
            value={cmp}
            onChange={(e) => setCmp(e.target.value as keyof typeof COMPARATOR)}
          >
            <option value="gte">observed ≥ target</option>
            <option value="gt">observed ＞ target</option>
            <option value="lt">observed ＜ target</option>
            <option value="lte">observed ≤ target</option>
          </select>
        </label>
        <label>
          Bet window (s)
          <input
            className="mt-1 w-full border border-[var(--rule)] bg-transparent p-2"
            type="number"
            value={betS}
            onChange={(e) => setBetS(e.target.value)}
          />
        </label>
        <label>
          Settle delay (s)
          <input
            className="mt-1 w-full border border-[var(--rule)] bg-transparent p-2"
            type="number"
            value={delay}
            onChange={(e) => setDelay(e.target.value)}
          />
        </label>
      </div>
      <button
        className="mt-4 w-full border border-[var(--ink)] py-2 text-sm disabled:opacity-40"
        disabled={!ready || send.busy}
      >
        File + schedule
      </button>
      {send.err && <p className="mt-2 text-xs text-[var(--no)]">{send.err}</p>}
      {send.hash && (
        <a
          className="mt-2 block text-xs underline"
          href={`${explorer}/tx/${send.hash}`}
          target="_blank"
          rel="noreferrer"
        >
          ledger
        </a>
      )}
    </form>
  );
}

function FundBox({
  ready,
  send,
}: {
  ready: boolean;
  send: ReturnType<typeof useSend>;
}) {
  const [amt, setAmt] = useState("0.4");
  return (
    <div className="border border-[var(--ink)] p-4">
      <h2 className="font-[family-name:var(--font-mono)] text-xs tracking-[0.25em] uppercase">
        Purse
      </h2>
      <p className="mt-2 text-sm italic opacity-80">
        Scheduler + HTTP fees come from RitualWallet, not from the ticket.
      </p>
      <input
        className="mt-3 w-full border border-[var(--rule)] bg-transparent p-2 text-sm"
        value={amt}
        onChange={(e) => setAmt(e.target.value)}
      />
      <button
        className="mt-3 w-full border border-[var(--ink)] py-2 text-sm disabled:opacity-40"
        disabled={!ready || send.busy}
        onClick={() => {
          if (!deskAddress) return;
          void send
            .send({
              address: deskAddress,
              abi: marketAbi,
              functionName: "fundExecution",
              args: [500000n],
              value: parseEther(amt || "0"),
            })
            .catch(() => undefined);
        }}
      >
        Seat the purse
      </button>
    </div>
  );
}

function WireBox() {
  const [print, setPrint] = useState<number | null>(null);
  const [edit, setEdit] = useState("4100");

  async function load() {
    const r = await fetch("/api/oracle/eth", { cache: "no-store" });
    const j = (await r.json()) as { price: number };
    setPrint(j.price);
  }

  useEffect(() => {
    void load();
    const id = setInterval(() => void load(), 4000);
    return () => clearInterval(id);
  }, []);

  const yes = (print ?? 0) >= DEMO.target;

  return (
    <div className="border border-[var(--ink)] p-4">
      <h2 className="font-[family-name:var(--font-mono)] text-xs tracking-[0.25em] uppercase">
        Wire
      </h2>
      <div className="mt-2 flex items-end justify-between">
        <div className="font-[family-name:var(--font-mono)] text-4xl">
          {print ?? "—"}
        </div>
        <div className="text-right text-xs">
          vs {DEMO.target}
          <div className={yes ? "text-[var(--yes)]" : "text-[var(--no)]"}>
            would {yes ? "YES" : "NO"}
          </div>
        </div>
      </div>
      <div className="mt-3 flex gap-2">
        <input
          className="flex-1 border border-[var(--rule)] bg-transparent p-2 text-sm"
          value={edit}
          onChange={(e) => setEdit(e.target.value)}
        />
        <button
          className="border border-[var(--ink)] px-3 text-sm"
          onClick={() => {
            void fetch("/api/oracle/eth", {
              method: "POST",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify({ price: Number(edit) }),
            }).then(load);
          }}
        >
          Set
        </button>
      </div>
      <p className="mt-2 break-all font-[family-name:var(--font-mono)] text-[10px] opacity-70">
        {feedHint || "tunnel /api/oracle/eth before live resolve"}
      </p>
    </div>
  );
}

function Ticket({
  row,
  me,
  ready,
  send,
  onDone,
}: {
  row: Row;
  me?: `0x${string}`;
  ready: boolean;
  send: ReturnType<typeof useSend>;
  onDone: () => void;
}) {
  const [stake, setStake] = useState("0.05");
  const pool = row.totalYes + row.totalNo;
  const yesPct = pool === 0n ? 50 : Number((row.totalYes * 1000n) / pool) / 10;

  const { data: mine } = useReadContract({
    address: deskAddress,
    abi: marketAbi,
    functionName: "stakesOf",
    args: me ? [row.id, me] : undefined,
    query: { enabled: Boolean(deskAddress && me) },
  });
  const [, , settled, claimable] = (mine as
    | readonly [bigint, bigint, boolean, bigint]
    | undefined) ?? [0n, 0n, false, 0n];

  function act(name: string, args: readonly unknown[], value?: bigint) {
    if (!deskAddress) return;
    void send
      .send({
        address: deskAddress,
        abi: marketAbi,
        functionName: name,
        args,
        value,
      })
      .then(onDone)
      .catch(() => undefined);
  }

  return (
    <article className="border border-[var(--ink)] p-4">
      <div className="flex items-start justify-between gap-3">
        <h3 className="text-xl leading-snug">{row.question}</h3>
        <span className="font-[family-name:var(--font-mono)] text-[10px] tracking-widest">
          {PHASE[row.state]} {row.outcome ? SIDE[row.outcome] : ""}
        </span>
      </div>
      <div className="mt-3 h-1 bg-[var(--rule)]">
        <div className="h-1 bg-[var(--yes)]" style={{ width: `${yesPct}%` }} />
      </div>
      <div className="mt-1 flex justify-between font-[family-name:var(--font-mono)] text-[11px]">
        <span>YES {yesPct.toFixed(0)}% {ink(row.totalYes)}</span>
        <span>NO {ink(row.totalNo)}</span>
      </div>
      <p className="mt-2 font-[family-name:var(--font-mono)] text-[11px] opacity-70">
        obs {MARK[row.comparator]} {row.target.toString()} · jq {row.jsonPath} ·
        close #{row.closeBlock.toString()}
      </p>
      {row.state === 0 && (
        <div className="mt-3 flex gap-2">
          <input
            className="w-24 border border-[var(--rule)] bg-transparent px-2 text-sm"
            value={stake}
            onChange={(e) => setStake(e.target.value)}
          />
          <button
            className="flex-1 bg-[var(--yes)] py-1 text-sm text-[var(--paper)] disabled:opacity-40"
            disabled={!ready || send.busy}
            onClick={() => act("bet", [row.id, true], parseEther(stake || "0"))}
          >
            YES
          </button>
          <button
            className="flex-1 bg-[var(--no)] py-1 text-sm text-[var(--paper)] disabled:opacity-40"
            disabled={!ready || send.busy}
            onClick={() => act("bet", [row.id, false], parseEther(stake || "0"))}
          >
            NO
          </button>
        </div>
      )}
      {row.state === 3 && !settled && claimable > 0n && (
        <button
          className="mt-3 w-full border border-[var(--ink)] py-1 text-sm"
          disabled={!ready || send.busy}
          onClick={() => act("claimWinnings", [row.id])}
        >
          Collect {ink(claimable)}
        </button>
      )}
      {row.state === 4 && !settled && claimable > 0n && (
        <button
          className="mt-3 w-full border border-[var(--ink)] py-1 text-sm"
          disabled={!ready || send.busy}
          onClick={() => act("claimRefund", [row.id])}
        >
          Return ticket {ink(claimable)}
        </button>
      )}
    </article>
  );
}
