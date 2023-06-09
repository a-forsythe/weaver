import { Fiber, Thread, spin } from '@a-forsythe/spinner';

export type Fabric = 'linen' | 'wool'

export type WeaveOrder = {
  fiber: Fiber
  quantity: number
}

export type WeaveFulfillment = {
  fabric: Fabric
  quantity: number
}

function weave(thread: Thread): Fabric {
  switch (thread) {
    case 'linen':
      return 'linen'
    case 'yarn':
      return 'wool'
    default:
      throw new Error(`Unrecognized thread type ${thread}`)
  }
}

export function fulfill(order: WeaveOrder): WeaveFulfillment {
  const { fiber, quantity } = order
  const thread = spin(fiber)
  const fabric = weave(thread)
  return { fabric, quantity }
}
