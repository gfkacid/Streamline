import { Button } from "@/components/ui/button";
import {
  TableHead,
  TableRow,
  TableHeader,
  TableCell,
  TableBody,
  Table,
} from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { JSX, SVGProps } from "react";
import Link from "next/link";
import {
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger,
} from "@/components/ui/tabs";
import {
  Select,
  SelectContent,
  SelectGroup,
  SelectItem,
  SelectLabel,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";

export default function PaymentsOverviewSection() {
  return (
    <div className="flex flex-col p-6">
      <h1 className="text-2xl font-bold mb-6">Payments overview</h1>
      <Tabs defaultValue="account" className="w-[400px]">
        <TabsList>
          <TabsTrigger value="account">Streaming Payments</TabsTrigger>
          <TabsTrigger value="password">Deposit Positions</TabsTrigger>
        </TabsList>
      </Tabs>
      <div className="flex justify-between items-center mt-4">
        <div>
          <Select>
            <SelectTrigger className="w-[180px]">
              <SelectValue placeholder="Payment Filter" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="light">All Payments</SelectItem>
              <SelectItem value="dark">Successful</SelectItem>
              <SelectItem value="system">Failed</SelectItem>
            </SelectContent>
          </Select>
        </div>
        <Link
          className="inline-flex h-10 items-center justify-center rounded-md px-8 border border-black border-2 shadow-left-bottom"
          href="/deposit"
        >
          Create Stream
        </Link>
      </div>
      <div className="overflow-x-auto mt-5">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead className="text-left">Stream Name</TableHead>
              <TableHead className="text-left">Receiver Address</TableHead>
              <TableHead className="text-left">Status</TableHead>
              <TableHead className="text-left">Amount</TableHead>
              <TableHead className="text-left">Current Stream</TableHead>
              <TableHead className="text-left">Creation Period</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            <TableRow>
              <TableCell>Landing page Freelance</TableCell>
              <TableCell>06c1774-7f3d-46ad...90a8</TableCell>
              <TableCell>
                <Badge variant="destructive">Succeeded</Badge>
              </TableCell>
              <TableCell>
                <CurrencyIcon className="inline-block mr-2" />
                6737.98
              </TableCell>
              <TableCell>
                <CurrencyIcon className="inline-block mr-2" />
                2000/6737.98
              </TableCell>
              <TableCell>Mar 23, 2022, 13:00 PM</TableCell>
            </TableRow>
          </TableBody>
        </Table>
      </div>
    </div>
  );
}

function CurrencyIcon(props: JSX.IntrinsicAttributes & SVGProps<SVGSVGElement>) {
  return (
    <svg
      {...props}
      xmlns="http://www.w3.org/2000/svg"
      width="24"
      height="24"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <circle cx="12" cy="12" r="8" />
      <line x1="3" x2="6" y1="3" y2="6" />
      <line x1="21" x2="18" y1="3" y2="6" />
      <line x1="3" x2="6" y1="21" y2="18" />
      <line x1="21" x2="18" y1="21" y2="18" />
    </svg>
  );
}
