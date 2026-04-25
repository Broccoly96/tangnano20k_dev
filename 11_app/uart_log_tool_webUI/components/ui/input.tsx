import * as React from "react";

import { cn } from "@/lib/utils";

const Input = React.forwardRef<HTMLInputElement, React.ComponentProps<"input">>(
  ({ className, type, ...props }, ref) => {
    return (
      <input
        type={type}
        className={cn(
          "flex h-10 w-full rounded-2xl border border-black/10 bg-white/75 px-4 py-2 text-sm text-stone-900 shadow-sm outline-none transition placeholder:text-stone-400 focus-visible:ring-2 focus-visible:ring-ring/60",
          className,
        )}
        ref={ref}
        {...props}
      />
    );
  },
);
Input.displayName = "Input";

export { Input };