from typing import Protocol, Literal
NotificationType=Literal['glucose_check','meal_follow_up','insulin','cycle','report_ready']
class NotificationService(Protocol):
    def send(self, user_id:str, kind:NotificationType, message:str) -> None: ...
