"use client";

import { useCallback, useState } from "react";
import { useWaitForTransactionReceipt, useWriteContract } from "wagmi";
import type { Abi, Address } from "viem";

export function useSend() {
  const { writeContractAsync, data: hash, reset } = useWriteContract();
  const { isLoading: wait, isSuccess } = useWaitForTransactionReceipt({ hash });
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const send = useCallback(
    async (p: {
      address: Address;
      abi: Abi | readonly unknown[];
      functionName: string;
      args?: readonly unknown[];
      value?: bigint;
    }) => {
      setErr(null);
      setBusy(true);
      try {
        return await writeContractAsync(p as never);
      } catch (e) {
        const m = e instanceof Error ? e.message.split("\n")[0] : "rejected";
        setErr(m ?? "rejected");
        throw e;
      } finally {
        setBusy(false);
      }
    },
    [writeContractAsync],
  );

  return { send, hash, err, busy: busy || wait, ok: isSuccess, reset };
}
