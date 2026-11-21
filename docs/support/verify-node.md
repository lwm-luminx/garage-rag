---
layout: default
title: Verifying a computer for Garage Door
description: Why Garage Remote and your other computers say a node "hasn't been verified by your account yet", which computer can verify it, and the steps.
---

# Verifying a computer for Garage Door

When you connect a second computer to your Garage Door account, it starts out **not verified**. Until it is, Garage
Remote on your phone says *"This node hasn't been verified by your account yet"* and won't open its library, and your
other computers won't share keys with it. Nothing is broken: one of your own computers has to vouch for the new one
first. Garage calls each computer a **node**, so that is the word the apps use.

## Why verifying is needed

The first computer you connect to Garage Door makes your **account key** and keeps it. It never leaves that
computer, and Garage Door only ever sees its public half. Each computer you add is trusted only once the account key
has signed for it. Your phone and your other computers check that signature themselves, so Garage Door can pass along
a computer's details but can't add one to your account or swap one in.

That is why you have to verify on **the computer that created your account**: it is the only one holding the account
key. Verifying on the new computer, or on any other one, doesn't work.

## Verify a computer

1. Make sure Garage is running on both computers and both are connected to Garage Door.
2. On **the computer that created your account**, open Garage and go to the **MCP Server** page. Under **Garage
   Door**, find **Linked Garages**. That computer says *"This node created your account. Verify your other nodes
   here."*
3. Find the new computer in the list. It says **Not verified yet**. Choose **Verify…**.
4. On **the new computer**, open the same **MCP Server** page and look at **Linked Garages**. Check that the code it
   shows as *This node's code* matches the code in the Verify sheet, and that the *Account code* matches on both
   screens.
5. If the codes match, choose **The Codes Match**. If they don't, choose **Cancel**: a different code means something
   is in between, and the computer should not be trusted.

The new computer then shows a verified seal. It receives your recovery key and the share keys your other computers
hold. In Garage Remote, try again: the computer opens like your first one.

## If something doesn't match these steps

<details>
<summary>I don't see Linked Garages</summary>
<p>Linked Garages appears once a computer is connected to Garage Door and your account's privacy level is <em>private
cluster</em> or higher. Garage Remote needs <em>private with end-to-end remote</em> or higher. You can change the level
from your Garage Door account.</p>
</details>

<details>
<summary>There's no Verify… button</summary>
<p>You're on a computer that didn't create your account. It shows <em>"Not verified yet: verify it on the node that
created your account"</em> beside the others. Go to the computer you connected to Garage Door first.</p>
</details>

<details>
<summary>The new computer isn't in the list</summary>
<p>Sign in to Garage Door with the same account on the new computer and leave Garage running there, then choose
<strong>Refresh</strong> under Linked Garages on the first computer.</p>
</details>

<details>
<summary>Garage Remote says "Open Garage on your node once it's connected to Garage Door"</summary>
<p>None of your computers has made an account key yet. Open Garage on the computer you want to use first, connect it
to Garage Door, and wait for Linked Garages to appear on its MCP Server page. That computer becomes the one that
verifies the rest.</p>
</details>

<details>
<summary>I no longer have the computer that created my account</summary>
<p>Your verified computers hold copies of your recovery key, but Garage can't move the account key to another
computer from its own screens yet. <a href="{{ '/support/contact.html' | relative_url }}">Contact support</a> and
we'll help.</p>
</details>

<details>
<summary>Can I use Garage Remote while I wait?</summary>
<p>Yes. Connect Garage Remote to a computer that is already verified, such as the one that created your account.</p>
</details>

More about how the door works and what it can see: [Garage Door]({{ '/door/' | relative_url }}).
